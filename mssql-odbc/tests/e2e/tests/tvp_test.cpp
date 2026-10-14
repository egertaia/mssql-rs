// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
//
// End-to-end coverage for table-valued parameters: describe identity, a
// populated round-trip, and an empty table. Mirrors the ODBC sequence a
// consumer (mssql-python) issues: prepare, describe, bind the SQL_SS_TABLE
// parameter, focus on it, bind its columns as arrays, restore focus, execute.

#include "odbc_test_fixture.h"

#include <array>
#include <string>
#include <vector>

#ifndef SQL_SS_TABLE
#define SQL_SS_TABLE (-153)
#endif
#ifndef SQL_SOPT_SS_PARAM_FOCUS
#define SQL_SOPT_SS_PARAM_FOCUS 1236
#endif
#ifndef SQL_CA_SS_SCHEMA_NAME
#define SQL_CA_SS_SCHEMA_NAME 1226
#endif
#ifndef SQL_CA_SS_TYPE_NAME
#define SQL_CA_SS_TYPE_NAME 1227
#endif

class TvpTest : public ODBCTest {
protected:
    void SetUp() override {
        ODBCTest::SetUp();
        ASSERT_TRUE(ODBCTestConfig::Instance().HasConnection());
        Connect();
        suffix_ = std::to_string(::GetTickCount64());
        type_name_ = "pytvp_type_" + suffix_;
        proc_name_ = "pytvp_proc_" + suffix_;
        Direct("DROP PROCEDURE IF EXISTS dbo.[" + proc_name_ + "]");
        Direct("DROP TYPE IF EXISTS dbo.[" + type_name_ + "]");
        ASSERT_SQL_OK(
            DirectRc("CREATE TYPE dbo.[" + type_name_ +
                     "] AS TABLE (id INT, label NVARCHAR(50))"),
            SQL_HANDLE_STMT, stmt_);
        // The proc returns the rows it received, so a fetch verifies what the
        // server actually materialized from the TVP on the wire.
        ASSERT_SQL_OK(
            DirectRc("CREATE PROCEDURE dbo.[" + proc_name_ +
                     "] @t dbo.[" + type_name_ +
                     "] READONLY AS SELECT id, label FROM @t ORDER BY id"),
            SQL_HANDLE_STMT, stmt_);
    }

    void TearDown() override {
        if (stmt_ != SQL_NULL_HSTMT) {
            Direct("DROP PROCEDURE IF EXISTS dbo.[" + proc_name_ + "]");
            Direct("DROP TYPE IF EXISTS dbo.[" + type_name_ + "]");
        }
        ODBCTest::TearDown();
    }

    SQLRETURN DirectRc(const std::string& sql) {
        auto text = ODBCTestUtils::ToSqlTStr(sql);
        return SQLExecDirect(stmt_, const_cast<SQLTCHAR*>(text.c_str()), SQL_NTS);
    }
    void Direct(const std::string& sql) { DirectRc(sql); }

    SQLRETURN Prepare(const std::string& sql) {
        auto text = ODBCTestUtils::ToSqlTStr(sql);
        return SQLPrepare(stmt_, const_cast<SQLTCHAR*>(text.c_str()), SQL_NTS);
    }

    SQLHDESC Ipd() {
        SQLHDESC ipd = SQL_NULL_HDESC;
        EXPECT_SQL_OK(SQLGetStmtAttrW(stmt_, SQL_ATTR_IMP_PARAM_DESC, &ipd, 0, nullptr),
                      SQL_HANDLE_STMT, stmt_);
        return ipd;
    }

    std::string suffix_;
    std::string type_name_;
    std::string proc_name_;
};

// SQLDescribeParam reports the TVP as SQL_SS_TABLE and the IPD exposes the
// table type's name through SQL_CA_SS_TYPE_NAME.
TEST_F(TvpTest, DescribeReportsTableTypeAndName) {
    ASSERT_SQL_OK(Prepare("EXEC dbo.[" + proc_name_ + "] ?"), SQL_HANDLE_STMT, stmt_);

    SQLSMALLINT data_type = 0;
    SQLULEN param_size = 0;
    SQLSMALLINT decimal_digits = 0;
    SQLSMALLINT nullable = 0;
    ASSERT_SQL_OK(SQLDescribeParam(stmt_, 1, &data_type, &param_size, &decimal_digits, &nullable),
                  SQL_HANDLE_STMT, stmt_);
    EXPECT_EQ(data_type, SQL_SS_TABLE);

    SQLWCHAR name[128] = {0};
    SQLINTEGER name_len = 0;
    ASSERT_SQL_OK(SQLGetDescFieldW(Ipd(), 1, SQL_CA_SS_TYPE_NAME, name,
                                   sizeof(name), &name_len),
                  SQL_HANDLE_DESC, Ipd());
    std::wstring got(name, name + name_len / sizeof(SQLWCHAR));
    std::wstring want(type_name_.begin(), type_name_.end());
    EXPECT_EQ(got, want);
}

// A populated TVP round-trips: two rows bound column-wise under param focus are
// returned verbatim by the procedure.
TEST_F(TvpTest, PopulatedTableRoundTrips) {
    ASSERT_SQL_OK(Prepare("EXEC dbo.[" + proc_name_ + "] ?"), SQL_HANDLE_STMT, stmt_);

    // The top-level TVP: value pointer is the type name, indicator the row count.
    std::wstring type_w(type_name_.begin(), type_name_.end());
    SQLLEN row_count = 2;
    ASSERT_SQL_OK(
        SQLBindParameter(stmt_, 1, SQL_PARAM_INPUT, SQL_C_BINARY, SQL_SS_TABLE,
                         static_cast<SQLULEN>(row_count), 0,
                         const_cast<SQLWCHAR*>(type_w.c_str()),
                         static_cast<SQLLEN>(type_w.size() * sizeof(SQLWCHAR)), &row_count),
        SQL_HANDLE_STMT, stmt_);
    std::wstring schema_w = L"dbo";
    ASSERT_SQL_OK(SQLSetDescFieldW(Ipd(), 1, SQL_CA_SS_SCHEMA_NAME,
                                   const_cast<SQLWCHAR*>(schema_w.c_str()),
                                   static_cast<SQLINTEGER>(schema_w.size() * sizeof(SQLWCHAR))),
                  SQL_HANDLE_DESC, Ipd());

    // Focus on the TVP and bind its two columns as arrays of row_count rows.
    ASSERT_SQL_OK(SQLSetStmtAttr(stmt_, SQL_SOPT_SS_PARAM_FOCUS,
                                 reinterpret_cast<SQLPOINTER>(1), SQL_IS_INTEGER),
                  SQL_HANDLE_STMT, stmt_);

    std::array<SQLINTEGER, 2> ids = {1, 2};
    std::array<SQLLEN, 2> id_ind = {0, 0};
    ASSERT_SQL_OK(SQLBindParameter(stmt_, 1, SQL_PARAM_INPUT, SQL_C_SLONG, SQL_INTEGER,
                                   0, 0, ids.data(), 0, id_ind.data()),
                  SQL_HANDLE_STMT, stmt_);

    // Two fixed-width wide-char rows, each padded to 50 chars + NUL.
    const SQLULEN label_cap = 50;
    std::vector<SQLWCHAR> labels((label_cap + 1) * 2, 0);
    std::array<SQLLEN, 2> label_ind = {0, 0};
    const wchar_t* texts[2] = {L"Keyboard", L"Mouse"};
    for (size_t r = 0; r < 2; ++r) {
        std::wstring t(texts[r]);
        for (size_t c = 0; c < t.size(); ++c) {
            labels[r * (label_cap + 1) + c] = static_cast<SQLWCHAR>(t[c]);
        }
        label_ind[r] = static_cast<SQLLEN>(t.size() * sizeof(SQLWCHAR));
    }
    ASSERT_SQL_OK(SQLBindParameter(stmt_, 2, SQL_PARAM_INPUT, SQL_C_WCHAR, SQL_WVARCHAR,
                                   label_cap, 0, labels.data(),
                                   static_cast<SQLLEN>((label_cap + 1) * sizeof(SQLWCHAR)),
                                   label_ind.data()),
                  SQL_HANDLE_STMT, stmt_);

    ASSERT_SQL_OK(SQLSetStmtAttr(stmt_, SQL_SOPT_SS_PARAM_FOCUS,
                                 reinterpret_cast<SQLPOINTER>(0), SQL_IS_INTEGER),
                  SQL_HANDLE_STMT, stmt_);

    ASSERT_SQL_OK(SQLExecute(stmt_), SQL_HANDLE_STMT, stmt_);

    // Row 1.
    ASSERT_SQL_OK(SQLFetch(stmt_), SQL_HANDLE_STMT, stmt_);
    SQLINTEGER id = 0;
    SQLLEN id_len = 0;
    SQLWCHAR label[64] = {0};
    SQLLEN label_len = 0;
    ASSERT_SQL_OK(SQLGetData(stmt_, 1, SQL_C_SLONG, &id, 0, &id_len), SQL_HANDLE_STMT, stmt_);
    ASSERT_SQL_OK(SQLGetData(stmt_, 2, SQL_C_WCHAR, label, sizeof(label), &label_len),
                  SQL_HANDLE_STMT, stmt_);
    EXPECT_EQ(id, 1);
    EXPECT_EQ(std::wstring(label), std::wstring(L"Keyboard"));

    // Row 2.
    ASSERT_SQL_OK(SQLFetch(stmt_), SQL_HANDLE_STMT, stmt_);
    ASSERT_SQL_OK(SQLGetData(stmt_, 1, SQL_C_SLONG, &id, 0, &id_len), SQL_HANDLE_STMT, stmt_);
    ASSERT_SQL_OK(SQLGetData(stmt_, 2, SQL_C_WCHAR, label, sizeof(label), &label_len),
                  SQL_HANDLE_STMT, stmt_);
    EXPECT_EQ(id, 2);
    EXPECT_EQ(std::wstring(label), std::wstring(L"Mouse"));

    EXPECT_EQ(SQLFetch(stmt_), SQL_NO_DATA);
}

// An empty TVP (indicator SQL_DEFAULT_PARAM, no column binds) yields zero rows.
TEST_F(TvpTest, EmptyTableYieldsNoRows) {
    ASSERT_SQL_OK(Prepare("EXEC dbo.[" + proc_name_ + "] ?"), SQL_HANDLE_STMT, stmt_);

    std::wstring type_w(type_name_.begin(), type_name_.end());
    SQLLEN indicator = SQL_DEFAULT_PARAM;
    ASSERT_SQL_OK(
        SQLBindParameter(stmt_, 1, SQL_PARAM_INPUT, SQL_C_BINARY, SQL_SS_TABLE, 0, 0,
                         const_cast<SQLWCHAR*>(type_w.c_str()),
                         static_cast<SQLLEN>(type_w.size() * sizeof(SQLWCHAR)), &indicator),
        SQL_HANDLE_STMT, stmt_);
    std::wstring schema_w = L"dbo";
    ASSERT_SQL_OK(SQLSetDescFieldW(Ipd(), 1, SQL_CA_SS_SCHEMA_NAME,
                                   const_cast<SQLWCHAR*>(schema_w.c_str()),
                                   static_cast<SQLINTEGER>(schema_w.size() * sizeof(SQLWCHAR))),
                  SQL_HANDLE_DESC, Ipd());

    ASSERT_SQL_OK(SQLExecute(stmt_), SQL_HANDLE_STMT, stmt_);
    EXPECT_EQ(SQLFetch(stmt_), SQL_NO_DATA);
}
