#!/bin/bash

# testName
#   -> testName_in.txt   なければエラー
#   -> testName_out.txt  あれば比較
#   -> testName_err.txt  あれば比較。outも両方ない場合はエラー

RUBY=`which ruby`
DIFF=`which diff`
CAT=`which cat`
TDCONV=tdconv.rb

TEST_DATA_DIR=`dirname $0`/test_data
TMP_OUT=/tmp/tdconv_stdout.txt
TMP_ERR=/tmp/tdconv_stderr.txt
DIFF_OUT=/tmp/tdconv_diff.txt

run_test() {

  test_name=$1; shift 1
  test_desc=$1; shift 1
  status_code=$1; shift 1
  args="$*"

  in_file="${TEST_DATA_DIR}/${test_name}_in.txt"
  out_file="${TEST_DATA_DIR}/${test_name}_out.txt"
  err_file="${TEST_DATA_DIR}/${test_name}_err.txt"

  echo "execute: ${test_name}"
  if [ "$test_desc" != "" ]; then
    echo "   desc: ${test_desc}"
  fi
  echo "   args: ${args}"

  if [ ! -e "$in_file" ]; then
    echo "input-file not found: $in_file"
    return 10
  fi

  # NegativeTestの場合は結果が無くても良い
  if [ $status_code -eq 0 ] && [ ! -e "$out_file" ] && [ ! -e "$err_file" ]; then
    echo "out-file and err-file not found."
    return 11
  fi

  # 実行する
  $RUBY $TDCONV $args 1>$TMP_OUT 2>$TMP_ERR < $in_file
  exit_code=$?

  # ステータスコードの検証
  if [ $status_code -ne $exit_code ]; then
    echo "  -> FAIL(status-code)"
    echo "     actual  =${exit_code}"
    echo "     expected=${status_code}"
    return 1
  fi

  # 結果の比較
  if [ -e "$out_file" ]; then
    $DIFF "$out_file" "$TMP_OUT" > $DIFF_OUT
    if [ $? -ne 0 ]; then
      echo "  -> FAIL(diff-stdout)"
      $CAT -A "$DIFF_OUT"
      return 2
    fi
  fi

  if [ -e "$err_file" ]; then
    $DIFF "$err_file" "$TMP_ERR" > $DIFF_OUT
    if [ $? -ne 0 ]; then
      echo "  -> FAIL(diff-stderr)"
      $CAT -A "$DIFF_OUT"
      return 3
    fi
  fi

  echo "  -> SUCCESS"
  return 0

}

# TSVのテスト
run_test "tsv_test1" "" 0 --input-format=tsv --use-header --types=int,int,int --output-format=json 
run_test "tsv_test2" "keys指定無し" 1 --input-format=tsv --types=int,int,int --output-format=json 
run_test "tsv_test3" "intの変換が0になる" 0 --input-format=tsv --keys=a,b,c --types=int,int,int --output-format=json 
run_test "tsv_test4" "skip-rowsのテスト" 0 --input-format=tsv --skip-rows=1 --keys=a,b,c --types=int,int,int --output-format=json 
run_test "tsv_test5" "keysとuse-headerではheaderが優先" 0 --input-format=tsv --use-header --keys=a,b,c --types=int,int,int --output-format=json 

# 型チェック
run_test "type_test1" "time以外" 0 --input-format=tsv --use-header --types=string,int,integer,long,bool,boolean,float,double --output-format=json 
run_test "type_test2" "boolバリエーション" 0 --input-format=tsv --use-header --types=bool,bool,bool,bool,bool,bool --output-format=json 
run_test "type_test3" "timeフォーマット指定なし" 0 --input-format=tsv --use-header --types=time --output-format=json 
run_test "type_test4" "timeフォーマット指定" 0 "--input-format=tsv --use-header --types=time[%Y-%m-%d],time[%Y-%m-%d_%T],time --output-format=json"
#run_test "type_test5" "timeフォーマット、デフォルト書換" 0 '--input-format=tsv --use-header --types=time --default-time-format="%F %T" --output-format=json'
run_test "type_test5" "timeフォーマット、デフォルト書換" 0 '--input-format=tsv --use-header --types=time --default-time-format=%F_%T --output-format=json'


# JSONのテスト
# REGEXのテスト
run_test "regex_test1" "" 0 --input-format=regex --keys=x,y,z --pattern="(\d+),(\d+),(\d+)" --types=int,int,int --output-format=json
run_test "regex_test2" "" 0 --input-format=regex --pattern="(?<xx>\d+),(?<yy>\d+),(?<zz>\d+)" --types=int,int,int --output-format=json
run_test "regex_test3" "" 0 --input-format=regex --keys=x,y,z --pattern="(?<xx>\d+),(?<yy>\d+),(?<zz>\d+)" --types=int,int,int --output-format=json

# TIMEオプション指定
#run_test "time_test1" "tsv" 0 --input-format=tsv --use-header --types=string,int --time-value=1347206460 --output-format=json
#run_test "time_test2" "tsv" 0 --input-format=tsv --use-header --types=string,int --time-value=2012/9/10_01:01:00 --time-format=%Y/%m/%d_%T --output-format=json

# 出力形式のテスト



