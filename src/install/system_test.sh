#!/bin/bash
# Copyright 2010 Google Inc. All Rights Reserved.
# Author: abliss@google.com (Adam Bliss)
#
# Generic system test, which should work on any implementation of
# Page Speed Automatic (not just the Apache module).
#
# Exits with status 0 if all tests pass.
# Exits with status 1 immediately if any test fails.
# Exits with status 2 if command line args are wrong.


if [ $# -lt 1 -o $# -gt 3 ]; then
  # Note: HOSTNAME and HTTPS_HOST should generally be localhost (when using
  # the default port) or localhost:PORT (when not). Specifically, by default
  # /mod_pagespeed_statistics is only accessible when accessed as localhost.
  echo Usage: $(basename $0) HOSTNAME [HTTPS_HOST [PROXY_HOST]]
  exit 2
fi;

TEMPDIR=${TEMPDIR-/tmp/mod_pagespeed_test.$USER}

# If the user has specified an alternate WGET as an environment variable, then
# use that, otherwise use the one in the path.
if [ "$WGET" == "" ]; then
  WGET=wget
else
  echo WGET = $WGET
fi

$WGET --version | head -1 | grep 1.12 >/dev/null
if [ $? != 0 ]; then
  echo You have the wrong version of wget.  1.12 is required.
  exit 1
fi

# Ditto for curl.
if [ "$CURL" == "" ]; then
  CURL=curl
else
  echo CURL = $CURL
fi

# Note that 'curl --version' exits with status 2 on CentOS even when
# curl is installed.
if ! which $CURL > /dev/null 2>&1; then
  echo "curl ($CURL) is not installed."
  exit 1
fi

# We need to set a wgetrc file because of the stupid way that the bash deals
# with strings and variable expansion.
mkdir -p $TEMPDIR || exit 1
export WGETRC=$TEMPDIR/wgetrc
# Use a Chrome User-Agent, so that we get real responses (including compression)
cat > $WGETRC <<EOF
user_agent = "Mozilla/5.0 (X11; U; Linux x86_64; en-US) AppleWebKit/534.0 (KHTML, like Gecko) Chrome/6.0.408.1 Safari/534.0"
EOF

HOSTNAME=$1
EXAMPLE_ROOT=http://$HOSTNAME/mod_pagespeed_example
STATISTICS_URL=http://$HOSTNAME/mod_pagespeed_statistics
BAD_RESOURCE_URL=http://$HOSTNAME/mod_pagespeed/W.bad.pagespeed.cf.hash.css
MESSAGE_URL=http://$HOSTNAME/mod_pagespeed_message

# The following shake-and-bake ensures that we set REWRITTEN_TEST_ROOT based on
# the TEST_ROOT in effect when we start up, if any, but if it was not set before
# invocation it is set to the newly-chosen TEST_ROOT.  This permits us to call
# this from other test scripts that use different host prefixes for rewritten
# content.
REWRITTEN_TEST_ROOT=$TEST_ROOT
TEST_ROOT=http://$HOSTNAME/mod_pagespeed_test
REWRITTEN_TEST_ROOT=${REWRITTEN_TEST_ROOT:-$TEST_ROOT}

# This sets up similar naming for https requests.
HTTPS_HOST=$2
HTTPS_EXAMPLE_ROOT=https://$HTTPS_HOST/mod_pagespeed_example

# These are the root URLs for rewritten resources; by default, no change.
REWRITTEN_ROOT=${REWRITTEN_ROOT:-$EXAMPLE_ROOT}

# Setup wget proxy information
export http_proxy=$3
export https_proxy=$3
export ftp_proxy=$3
export no_proxy=""

# Version timestamped with nanoseconds, making it extremely unlikely to hit.
BAD_RND_RESOURCE_URL="http://$HOSTNAME/mod_pagespeed/bad`date +%N`.\
pagespeed.cf.hash.css"

combine_css_filename=\
styles/yellow.css+blue.css+big.css+bold.css.pagespeed.cc.xo4He3_gYf.css

OUTDIR=$TEMPDIR/fetched_directory
rm -rf $OUTDIR

# Wget is used three different ways.  The first way is nonrecursive and dumps a
# single page (with headers) to standard out.  This is useful for grepping for a
# single expected string that's the result of a first-pass rewrite:
#   wget -q -O --save-headers - $URL | grep -q foo
# "-q" quells wget's noisy output; "-O -" dumps to stdout; grep's -q quells
# its output and uses the return value to indicate whether the string was
# found.  Note that exiting with a nonzero value will immediately kill
# the make run.
#
# Sometimes we want to check for a condition that's not true on the first dump
# of a page, but becomes true after a few seconds as the server's asynchronous
# fetches complete.  For this we use the the fetch_until() function:
#   fetch_until $URL 'grep -c delayed_foo' 1
# In this case we will continuously fetch $URL and pipe the output to
# grep -c (which prints the count of matches); we repeat until the number is 1.
#
# The final way we use wget is in a recursive mode to download all prerequisites
# of a page.  This fetches all resources associated with the page, and thereby
# validates the resources generated by mod_pagespeed:
#   wget -H -p -S -o $WGET_OUTPUT -nd -P $OUTDIR $EXAMPLE_ROOT/$FILE
# Here -H allows wget to cross hosts (e.g. in the case of a sharded domain); -p
# means to fetch all prerequisites; "-S -o $WGET_OUTPUT" saves wget output
# (including server headers) for later analysis; -nd puts all results in one
# directory; -P specifies that directory.  We can then run commands on
# $OUTDIR/$FILE and nuke $OUTDIR when we're done.
# TODO(abliss): some of these will fail on windows where wget escapes saved
# filenames differently.
# TODO(morlovich): This isn't actually true, since we never pass in -r,
#                  so this fetch isn't recursive. Clean this up.


WGET_OUTPUT=$OUTDIR/wget_output.txt
WGET_DUMP="$WGET -q -O - --save-headers"
WGET_DUMP_HTTPS="$WGET -q -O - --save-headers --no-check-certificate"
WGET_PREREQ="$WGET -H -p -S -o $WGET_OUTPUT -nd -P $OUTDIR -e robots=off"
WGET_ARGS=""

function run_wget_with_args() {
  $WGET_PREREQ $WGET_ARGS "$@"
}

# Call with a command and its args.  Echos the command, then tries to eval it.
# If it returns false, fail the tests.
function check() {
  echo "     " "$@"
  if "$@"; then
    return;
  else
    echo FAIL.
    exit 1;
  fi;
}

# Same as check(), but expects command to fail.
function check_not() {
  echo "     " "$@"
  if "$@"; then
    echo FAIL.
    exit 1;
  else
    return;
  fi;
}

# Continuously fetches URL and pipes the output to COMMAND.  Loops until
# COMMAND outputs RESULT, in which case we return 0, or until 10 seconds have
# passed, in which case we return 1.
function fetch_until() {
  # Should not user URL as PARAM here, it rewrites value of URL for
  # the rest tests.
  REQUESTURL=$1
  COMMAND=$2
  RESULT=$3
  WGET_ARGS="$WGET_ARGS $4"

  TIMEOUT=10
  START=`date +%s`
  STOP=$((START+$TIMEOUT))
  WGET_HERE="$WGET -q $WGET_ARGS"
  echo "      Fetching $REQUESTURL $WGET_ARGS until \$($COMMAND) = $RESULT"
  echo "$WGET_HERE -O - $REQUESTURL 2>&1 | $COMMAND"
  while test -t; do
    if [ "$($WGET_HERE -O - $REQUESTURL 2>&1 | $COMMAND)" = "$RESULT" ]; then
      /bin/echo ".";
      return;
    fi;
    if [ `date +%s` -gt $STOP ]; then
      /bin/echo "FAIL."
      exit 1;
    fi;
    /bin/echo -n "."
    sleep 0.1
  done;
}


# Helper to set up most filter tests.  Alternate between using query-params
# and request-headers to enable the filter, so we know they both work.
filter_spec_method="query_params"
function test_filter() {
  rm -rf $OUTDIR
  mkdir -p $OUTDIR
  FILTER_NAME=$1;
  shift;
  FILTER_DESCRIPTION=$@
  echo TEST: $FILTER_NAME $FILTER_DESCRIPTION
  # Filename is the name of the first filter only.
  FILE=${FILTER_NAME%%,*}.html
  if [ $filter_spec_method = "query_params" ]; then
    WGET_ARGS=""
    FILE="$FILE?ModPagespeedFilters=$FILTER_NAME"
    filter_spec_method="headers"
  else
    WGET_ARGS="--header=ModPagespeedFilters:$FILTER_NAME"
    filter_spec_method="query_params"
  fi
  URL=$EXAMPLE_ROOT/$FILE
  FETCHED=$OUTDIR/$FILE
}

# Helper to test if we mess up extensions on requests to broken url
function test_resource_ext_corruption() {
  URL=$1
  RESOURCE=$EXAMPLE_ROOT/$2

  # Make sure the resource is actually there, that the test isn't broken
  echo checking that wgetting $URL finds $RESOURCE ...
  $WGET_DUMP $WGET_ARGS $URL | check fgrep -qi $RESOURCE

  # Now fetch the broken version. This should succeed anyway, as we now
  # ignore the noise.
  BROKEN="$RESOURCE"broken
  check $WGET_PREREQ $WGET_ARGS $BROKEN

  # Fetch normal again; ensure rewritten url for RESOURCE doesn't contain broken
  $WGET_DUMP $WGET_ARGS $URL | check_not fgrep "broken"
}

# Inner helper to test directive ModPagespeedForBots By default
# directive ModPagespeedForBots is off; otherwise image rewriting is
# disabled for bots while other filters such as inline_css still work.
function CheckBots() {
  WGET_ARGS=""
  ON=$1
  COMPARE=$2
  USER_AGENT=$3
  DRY_RUN_OR_TEST=$4
  ARGS="--header=ModPagespeedFilters:inline_css,rewrite_images"
  FILE="bot_test.html"

  rm -rf $OUTDIR
  mkdir -p $OUTDIR

  # By default ModPagespeedDisableForBots is false, no need to set it in url.
  # If the test wants to set it explicitly, set it in url.
  if [[ $ON != "default" ]]; then
    ARGS="$ARGS --header=ModPagespeedDisableForBots:$ON"
  fi
  if [[ $USER_AGENT != "default" ]]; then
    ARGS="$ARGS -U $USER_AGENT"
  fi

  FETCHED=$OURDIR/$FILE
  URL=$TEST_ROOT/$FILE
  # Filters such as inline_css work no matter if ModPagespeedDisable is on
  # Fetch until CSS is inlined, so that we know rewriting succeeded.
  fetch_until $URL 'grep -c style' 2 "$ARGS"

  # Check if the images are rewritten
  rm -f $OUTDIR/*png*
  rm -f $OUTDIR/*jpg*
  check $WGET_PREREQ $ARGS $URL;
  if [ "$DRY_RUN_OR_TEST" = "test" ]; then
    check [ `stat -c %s $OUTDIR/*BikeCrashIcn*` $COMPARE 25000 ] # recoded | not
    check [ `stat -c %s $OUTDIR/*Puzzle*`  $COMPARE 24126  ] # resized | not
  fi
}

# Outer helper function to test bots.  This is used to initiate a "dry run"
# for the bot-tests early in the system-test, ignoring the results.  This
# initiates asynchronous rewrites which will almost certainly finish by the
# end of the system-tests, when we'll re-run the test with checking enabled.
#
# This process is inherently racy.  A robust implementation could be
# built by polling mod_pagespeed statistics and waiting until all
# outstanding rewrites are complete.
#
# TODO(jmarantz): Instead of warming the meta-data cache with a dry run,
# use a statistics 'rewrite_cached_output_missed_deadline' to determine
# whether the system is settled yet.
function CheckBotTest() {
  echo "$1: UserAgent is a bot; ModPagespeedDisableForBots=off"
  CheckBots 'off' '-lt' 'Googlebot/2.1' "$1"
  echo "$1: UserAgent is a bot; ModPagespeedDisableForBots=on"
  CheckBots 'on' '-gt' 'Googlebot/2.1' "$1"
  echo "$1: UserAgent is a bot; ModPagespeedDisableForBots is default"
  CheckBots 'default' '-lt' 'Googlebot/2.1' "$1"
  echo "$1: UserAgent is not a bot, ModPagespeedDisableForBots=off"
  CheckBots 'off' '-lt' default "$1"
  echo "$1: UserAgent is not a bot, ModPagespeedDisableForBots=on"
  CheckBots 'on' '-lt' default "$1"
  echo "$1: UserAgent is not a bot, ModPagespeedDisableForBots is default"
  CheckBots 'default' '-lt' default "$1"
}

# General system tests

echo TEST: Page Speed Automatic is running and writes the expected header.
echo $WGET_DUMP $EXAMPLE_ROOT/combine_css.html

# Due to the extreme pickiness of our metadata cache, and the negative
# checks done in bot-testing (checking for the absence of image rewrites)
# we need to warm the metadata cache with a dry run.  Here we do all the
# bot tests, but we don't expect the outputs to be correct yet.  We will
# need to perform new image compressions for every option-change.
#
# This is required because we sign metadata cache keys using the entire
# contents of RewriteOptions.
CheckBotTest "Dry Run"

HTTP_FILE=$OUTDIR/http_file
# Note: We pipe this to a file instead of storing it in a variable because
# saving strings to variables converts "\n" -> " " inexplicably.
$WGET_DUMP $EXAMPLE_ROOT/combine_css.html > $HTTP_FILE

echo Checking for X-Mod-Pagespeed header
check egrep -q 'X-Mod-Pagespeed|X-Page-Speed' $HTTP_FILE

echo "Checking that we don't have duplicate X-Mod-Pagespeed headers"
check [ `egrep -c 'X-Mod-Pagespeed|X-Page-Speed' $HTTP_FILE` = 1 ]

echo "Checking that we don't have duplicate headers"
# Note: uniq -d prints only repeated lines. So this should only != "" if
# There are repeated lines in header.
repeat_lines=$(grep ":" $HTTP_FILE | sort | uniq -d)
check [ "$repeat_lines" = "" ]

echo Checking for lack of E-tag
check_not fgrep -i Etag $HTTP_FILE

echo Checking for presence of Vary.
check fgrep -qi 'Vary: Accept-Encoding' $HTTP_FILE

echo Checking for absence of Last-Modified
check_not fgrep -i 'Last-Modified' $HTTP_FILE

# Note: This is in flux, we can now allow cacheable HTML and this test will
# need to be updated if this is turned on by default.
echo Checking for presence of Cache-Control: max-age=0, no-cache
check fgrep -qi 'Cache-Control: max-age=0, no-cache' $HTTP_FILE

# TODO(sligocki): We should have Expires headers in HTML just like resources.
#echo Checking for absence of Expires
#check_not fgrep -i 'Expires' $HTTP_FILE

echo Checking for absence of X-Frame-Options: SAMEORIGIN
check_not fgrep -i "X-Frame-Options" $HTTP_FILE

# This tests whether fetching "/" gets you "/index.html".  With async
# rewriting, it is not deterministic whether inline css gets
# rewritten.  That's not what this is trying to test, so we use
# ?ModPagespeed=off.
echo TEST: directory is mapped to index.html.
rm -rf $OUTDIR
mkdir -p $OUTDIR
check $WGET -q $EXAMPLE_ROOT/?ModPagespeed=off -O $OUTDIR/mod_pagespeed_example
check $WGET -q $EXAMPLE_ROOT/index.html?ModPagespeed=off -O $OUTDIR/index.html
check diff $OUTDIR/index.html $OUTDIR/mod_pagespeed_example

echo TEST: compression is enabled for HTML.
$WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' $EXAMPLE_ROOT/ 2>&1 \
  | check fgrep -qi 'Content-Encoding: gzip'

echo TEST: X-Mod-Pagespeed header added when ModPagespeed=on
$WGET_DUMP $EXAMPLE_ROOT/combine_css.html?ModPagespeed=on \
  | check egrep -q 'X-Mod-Pagespeed|X-Page-Speed'

echo TEST: X-Mod-Pagespeed header not added when ModPagespeed=off
$WGET_DUMP $EXAMPLE_ROOT/combine_css.html?ModPagespeed=off \
  | check_not egrep 'X-Mod-Pagespeed|X-Page-Speed'

echo TEST: We behave sanely on whitespace served as HTML
FETCHED=$OUTDIR/whitespace.html
$WGET_DUMP $TEST_ROOT/whitespace.html > $FETCHED
check egrep -q 'HTTP/1[.]. 200 OK' $FETCHED

# Individual filter tests, in alphabetical order

test_filter add_instrumentation adds 2 script tags
check run_wget_with_args $URL
# Counts occurances of '<script' in $FETCHED
# See: http://superuser.com/questions/339522
check [ $(fgrep -o '<script' $FETCHED | wc -l) -eq 2 ]

echo "TEST: We don't add_instrumentation if URL params tell us not to"
FILE=add_instrumentation.html?ModPagespeedFilters=
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
check run_wget_with_args $URL
check [ $(fgrep -o '<script' $FETCHED | wc -l) -eq 0 ]

# http://code.google.com/p/modpagespeed/issues/detail?id=170
echo "TEST: Make sure 404s aren't rewritten"
# Note: We run this in the add_instrumentation section because that is the
# easiest to detect which changes every page
THIS_BAD_URL=$BAD_RESOURCE_URL?ModPagespeedFilters=add_instrumentation
# We use curl, because wget does not save 404 contents
$CURL --silent $THIS_BAD_URL | fgrep /mod_pagespeed_beacon
check [ $? != 0 ]

test_filter collapse_whitespace removes whitespace, but not from pre tags.
check run_wget_with_args $URL
check [ $(egrep -c '^ +<' $FETCHED) -eq 1 ]

test_filter combine_css combines 4 CSS files into 1.
fetch_until $URL 'fgrep -c text/css' 1
check run_wget_with_args $URL
#test_resource_ext_corruption $URL $combine_css_filename

echo TEST: combine_css without hash field should 404
echo run_wget_with_args $REWRITTEN_ROOT/styles/yellow.css+blue.css.pagespeed.cc..css
run_wget_with_args $REWRITTEN_ROOT/styles/yellow.css+blue.css.pagespeed.cc..css
check fgrep "404 Not Found" $WGET_OUTPUT

# Note: this large URL can only be processed by Apache if
# ap_hook_map_to_storage is called to bypass the default
# handler that maps URLs to filenames.
echo TEST: Fetch large css_combine URL
LARGE_URL="$REWRITTEN_ROOT/styles/yellow.css+blue.css+big.css+\
bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+bold.css+yellow.css+blue.css+\
big.css+bold.css+yellow.css+blue.css+big.css+\
bold.css.pagespeed.cc.46IlzLf_NK.css"
echo "$WGET --save-headers -q -O - $LARGE_URL | head -1 | egrep \"HTTP/1[.]. 200 OK\""
$WGET --save-headers -q -O - $LARGE_URL | head -1 | egrep "HTTP/1[.]. 200 OK"
check [ $? = 0 ];
LARGE_URL_LINE_COUNT=$($WGET -q -O - $LARGE_URL | wc -l)
check [ $? = 0 ]
echo Checking that response body is at least 900 lines -- it should be 954
check [ $LARGE_URL_LINE_COUNT -gt 900 ]

test_filter combine_javascript combines 2 JS files into 1.
fetch_until $URL 'fgrep -c src=' 1
check run_wget_with_args $URL

echo TEST: combine_javascript with long URL still works
URL=$TEST_ROOT/combine_js_very_many.html?ModPagespeedFilters=combine_javascript
fetch_until $URL 'fgrep -c src=' 4

test_filter combine_heads combines 2 heads into 1
check run_wget_with_args $URL
check [ `fgrep -c '<head>' $FETCHED` = 1 ]

test_filter elide_attributes removes boolean and default attributes.
check run_wget_with_args $URL
check_not fgrep "disabled=" $FETCHED   # boolean, should not find
check_not fgrep "type=" $FETCHED       # default, should not find

test_filter extend_cache_images rewrites an image tag.
URL=$EXAMPLE_ROOT/extend_cache.html?ModPagespeedFilters=extend_cache_images
fetch_until $URL 'egrep -c src.*/Puzzle[.]jpg[.]pagespeed[.]ce[.].*[.]jpg' 1
check run_wget_with_args $URL
echo about to test resource ext corruption...
#test_resource_ext_corruption $URL images/Puzzle.jpg.pagespeed.ce.91_WewrLtP.jpg

echo TEST: Attempt to fetch cache-extended image without hash should 404
run_wget_with_args $REWRITTEN_ROOT/images/Puzzle.jpg.pagespeed.ce..jpg
check fgrep "404 Not Found" $WGET_OUTPUT

echo TEST: Cache-extended image should respond 304 to an If-Modified-Since.
URL=$REWRITTEN_ROOT/images/Puzzle.jpg.pagespeed.ce.91_WewrLtP.jpg
DATE=`date -R`
run_wget_with_args --header "If-Modified-Since: $DATE" $URL
check grep "304 Not Modified" $WGET_OUTPUT

echo TEST: Legacy format URLs should still work.
URL=$REWRITTEN_ROOT/images/ce.0123456789abcdef0123456789abcdef.Puzzle,j.jpg
# Note: Wget request is HTTP/1.0, so some servers respond back with
# HTTP/1.0 and some respond back 1.1.
$WGET_DUMP $URL > $FETCHED
check egrep -q 'HTTP/1[.]. 200 OK' $FETCHED

echo TEST: Filters do not rewrite blacklisted JavaScript files.
URL=$TEST_ROOT/blacklist/blacklist.html?ModPagespeedFilters=extend_cache,rewrite_javascript,trim_urls
FETCHED=$OUTDIR/blacklist.html
fetch_until $URL 'grep -c .js.pagespeed.' 4
$WGET_DUMP $URL > $FETCHED
cat $FETCHED
check grep "<script src=\".*normal\.js\.pagespeed\..*\.js\">" $FETCHED
check grep "<script src=\"js_tinyMCE\.js\"></script>" $FETCHED
check grep "<script src=\"tiny_mce\.js\"></script>" $FETCHED
check grep "<script src=\"tinymce\.js\"></script>" $FETCHED
check grep "<script src=\"scriptaculous\.js?load=effects,builder\"></script>" \
  $FETCHED
check grep "<script src=\"connect\.facebook\.net/en_US/all\.js\"></script>" \
  $FETCHED
check grep "<script src=\".*jquery.*\.js\.pagespeed\..*\.js\">" $FETCHED
check grep "<script src=\".*ckeditor\.js\">" $FETCHED
check grep "<script src=\".*swfobject\.js\.pagespeed\..*\.js\">" $FETCHED
check grep "<script src=\".*another_normal\.js\.pagespeed\..*\.js\">" $FETCHED

WGET_ARGS=""
echo TEST: move_css_above_scripts works.
URL=$EXAMPLE_ROOT/move_css_above_scripts.html?ModPagespeedFilters=move_css_above_scripts
$WGET_DUMP $URL > $FETCHED
# Link moved before script.
cat $FETCHED
check grep -q "styles/all_styles.css\"><script" $FETCHED

echo TEST: move_css_above_scripts off.
URL=$EXAMPLE_ROOT/move_css_above_scripts.html?ModPagespeedFilters=
$WGET_DUMP $URL > $FETCHED
# Link not moved before script.
check_not grep "styles/all_styles.css\"><script" $FETCHED

echo TEST: move_css_to_head does what it says on the tin.
URL=$EXAMPLE_ROOT/move_css_to_head.html?ModPagespeedFilters=move_css_to_head
$WGET_DUMP $URL > $FETCHED
# Link moved to head.
check grep -q "styles/all_styles.css\"></head>" $FETCHED

echo TEST: move_css_to_head off.
URL=$EXAMPLE_ROOT/move_css_to_head.html?ModPagespeedFilters=
$WGET_DUMP $URL > $FETCHED
# Link not moved to head.
check_not grep "styles/all_styles.css\"></head>" $FETCHED

test_filter inline_css converts a link tag to a style tag.
fetch_until $URL 'grep -c style' 2

test_filter inline_javascript inlines a small JS file.
fetch_until $URL 'grep -c document.write' 1

test_filter outline_css outlines large styles, but not small ones.
check run_wget_with_args $URL
check egrep -q '<link.*text/css.*large' $FETCHED  # outlined
check egrep -q '<style.*small' $FETCHED           # not outlined

test_filter outline_javascript outlines large scripts, but not small ones.
check run_wget_with_args $URL
check egrep -q '<script.*large.*src=' $FETCHED       # outlined
check egrep -q '<script.*small.*var hello' $FETCHED  # not outlined
echo TEST: compression is enabled for rewritten JS.
JS_URL=$(egrep -o http://.*.pagespeed.*.js $FETCHED)
echo "JS_URL=\$\(egrep -o http://.*[.]pagespeed.*[.]js $FETCHED\)=\"$JS_URL\""
JS_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $JS_URL 2>&1)
echo JS_HEADERS=$JS_HEADERS
echo $JS_HEADERS | check egrep -qi 'HTTP/1[.]. 200 OK'
echo $JS_HEADERS | check fgrep -qi 'Content-Encoding: gzip'
#echo $JS_HEADERS | check fgrep -qi 'Vary: Accept-Encoding'
echo $JS_HEADERS | check fgrep -qi 'Etag: W/0'
echo $JS_HEADERS | check fgrep -qi 'Last-Modified:'

test_filter remove_comments removes comments but not IE directives.
check run_wget_with_args $URL
check_not grep removed $FETCHED   # comment, should not find
check grep -q preserved $FETCHED  # preserves IE directives

test_filter remove_quotes does what it says on the tin.
check run_wget_with_args $URL
num_quoted=$(sed 's/ /\n/g' $FETCHED | grep -c '"')
check [ $num_quoted -eq 2 ]  # 2 quoted attrs
num_apos=$(grep -c "'" $FETCHED)
check [ $num_apos -eq 0 ]                    # no apostrophes

test_filter trim_urls makes urls relative
check run_wget_with_args $URL
check_not grep "mod_pagespeed_example" $FETCHED  # base dir, shouldn't find
check [ `stat -c %s $FETCHED` -lt 153 ]        # down from 157

test_filter rewrite_css minifies CSS and saves bytes.
fetch_until $URL 'grep -c comment' 0
check run_wget_with_args $URL
check [ `stat -c %s $FETCHED` -lt 680 ]  # down from 689

test_filter rewrite_images inlines, compresses, and resizes.
fetch_until $URL 'grep -c data:image/png' 1  # inlined
fetch_until $URL 'grep -c .pagespeed.ic' 2   # other 2 images optimized
check run_wget_with_args $URL
check [ "$(stat -c %s $OUTDIR/xBikeCrashIcn*)" -lt 25000 ]      # re-encoded
check [ "$(stat -c %s $OUTDIR/*256x192*Puzzle*)"  -lt 24126  ]  # resized
URL=$EXAMPLE_ROOT"/rewrite_images.html?ModPagespeedFilters=rewrite_images"
IMG_URL=$(egrep -o http://.*.pagespeed.*.jpg $FETCHED | head -n1)
check [ x"$IMG_URL" != x ]
echo TEST: headers for rewritten image "$IMG_URL"
IMG_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $IMG_URL 2>&1)
echo "IMG_HEADERS=\"$IMG_HEADERS\""
echo $IMG_HEADERS | check egrep -qi 'HTTP/1[.]. 200 OK'
# Make sure we have some valid headers.
echo "$IMG_HEADERS" | check fgrep -qi 'Content-Type: image/jpeg'
# Make sure the response was not gzipped.
echo TEST: Images are not gzipped.
echo "$IMG_HEADERS" | check_not fgrep -i 'Content-Encoding: gzip'
# Make sure there is no vary-encoding
echo TEST: Vary is not set for images.
echo "$IMG_HEADERS" | check_not fgrep -i 'Vary: Accept-Encoding'
# Make sure there is an etag
echo TEST: Etags is present.
echo "$IMG_HEADERS" | check fgrep -qi 'Etag: W/0'
# TODO(sligocki): Allow setting arbitrary headers in static_server.
# Make sure an extra header is propagated from input resource to output
# resource.  X-Extra-Header is added in debug.conf.template.
#echo TEST: Extra header is present
#echo "$IMG_HEADERS" | check fgrep -qi 'X-Extra-Header'
# Make sure there is a last-modified tag
echo TEST: Last-modified is present.
echo "$IMG_HEADERS" | check fgrep -qi 'Last-Modified'

BAD_IMG_URL=$REWRITTEN_ROOT/images/xBadName.jpg.pagespeed.ic.Zi7KMNYwzD.jpg
echo TEST: rewrite_images fails broken image \"$BAD_IMG_URL\".
echo run_wget_with_args $BAD_IMG_URL
run_wget_with_args $BAD_IMG_URL  # fails
check grep "404 Not Found" $WGET_OUTPUT

# [google] b/3328110
echo "TEST: rewrite_images doesn't 500 on unoptomizable image."
IMG_URL=$REWRITTEN_ROOT/images/xOptPuzzle.jpg.pagespeed.ic.Zi7KMNYwzD.jpg
run_wget_with_args $IMG_URL
check egrep "HTTP/1[.]. 200 OK" $WGET_OUTPUT

# These have to run after image_rewrite tests. Otherwise it causes some images
# to be loaded into memory before they should be.
WGET_ARGS=""
echo TEST: rewrite_css,extend_cache extends cache of images in CSS.
FILE=rewrite_css_images.html?ModPagespeedFilters=rewrite_css,extend_cache
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
fetch_until $URL 'grep -c Cuppa.png.pagespeed.ce.' 1  # image cache extended
fetch_until $URL 'grep -c rewrite_css_images.css.pagespeed.cf.' 1
check run_wget_with_args $URL

echo TEST: fallback_rewrite_css_urls works.
FILE=fallback_rewrite_css_urls.html?\
ModPagespeedFilters=fallback_rewrite_css_urls,rewrite_css,extend_cache
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
fetch_until $URL 'grep -c Cuppa.png.pagespeed.ce.' 1  # image cache extended
fetch_until $URL 'grep -c fallback_rewrite_css_urls.css.pagespeed.cf.' 1
check run_wget_with_args $URL
# Test this was fallback flow -> no minification.
check grep -q "body { background" $FETCHED

# Rewrite images in styles.
echo TEST: rewrite_images,rewrite_css,rewrite_style_attributes_with_url optimizes images in style.
FILE=rewrite_style_attributes.html?ModPagespeedFilters=rewrite_images,rewrite_css,rewrite_style_attributes_with_url
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
fetch_until $URL 'grep -c BikeCrashIcn.png.pagespeed.ic.' 1
check run_wget_with_args $URL

echo TEST: rewrite_css,rewrite_images rewrites images in CSS.
FILE=rewrite_css_images.html?ModPagespeedFilters=rewrite_css,rewrite_images
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
fetch_until $URL 'grep -c url.data:image/png;base64,' 1  # image inlined
fetch_until $URL 'grep -c rewrite_css_images.css.pagespeed.cf.' 1
check run_wget_with_args $URL

echo TEST: inline_css,rewrite_css,sprite_images sprites images in CSS.
FILE=sprite_images.html?ModPagespeedFilters=inline_css,rewrite_css,sprite_images
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
echo $WGET_DUMP $URL
fetch_until $URL \
'grep -c Cuppa.png.*BikeCrashIcn.png.*IronChef2.gif.*.pagespeed.is.*.png' 1

echo TEST: rewrite_css,sprite_images sprites images in CSS.
FILE=sprite_images.html?ModPagespeedFilters=rewrite_css,sprite_images
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
echo $WGET_DUMP $URL
fetch_until $URL 'grep -c css.pagespeed.cf' 1
echo $WGET_DUMP $URL
$WGET_DUMP $URL > $OUTDIR/sprite_output
CSS=`grep stylesheet $OUTDIR/sprite_output | cut -d\" -f 6`
echo css is $CSS
$WGET_DUMP $CSS > $OUTDIR/sprite_css_output
cat $OUTDIR/sprite_css_output
echo ""
check [ `grep -c "ic.pagespeed.is" $OUTDIR/sprite_css_output` -gt 0 ]

test_filter rewrite_javascript minifies JavaScript and saves bytes.
# External scripts rewritten.
fetch_until $URL 'grep -c src.*/rewrite_javascript\.js\.pagespeed\.jm\.' 2
check run_wget_with_args $URL
grep -R "removed" $OUTDIR                 # Comments, should not find any.
check [ $? != 0 ]
check [ "$(stat -c %s $FETCHED)" -lt 1560 ]  # Net savings
check grep -q preserved $FETCHED             # Preserves certain comments.
# Rewritten JS is cache-extended.
check grep -qi "Cache-control: max-age=31536000" $WGET_OUTPUT
check grep -qi "Expires:" $WGET_OUTPUT

# Error path for fetch of outlined resources that are not in cache leaked
# at one point of development.
echo TEST: regression test for RewriteDriver leak
$WGET -O /dev/null -o /dev/null $TEST_ROOT/_.pagespeed.jo.3tPymVdi9b.js

# Combination rewrite in which the same URL occurred twice used to
# lead to a large delay due to overly late lock release.
echo TEST: regression test with same filtered input twice in combination
PAGE=_,Mco.0.css+_,Mco.0.css.pagespeed.cc.0.css
URL=$TEST_ROOT/$PAGE?ModPagespeedFilters=combine_css,outline_css
echo $WGET -O /dev/null -o /dev/null --tries=1 --read-timeout=3 $URL
$WGET -O /dev/null -o /dev/null --tries=1 --read-timeout=3 $URL
# We want status code 8 (server-issued error) and not 4
# (network failure/timeout)
check [ $? = 8 ]

CheckBotTest "test"

WGET_ARGS=""

# Simple test that https is working.
if [ -n "$HTTPS_HOST" ]; then
  URL="$HTTPS_EXAMPLE_ROOT/combine_css.html"
  fetch_until $URL 'grep -c css+' 1 --no-check-certificate

  echo TEST: https is working.
  echo $WGET_DUMP_HTTPS $URL
  HTML_HEADERS=$($WGET_DUMP_HTTPS $URL)

  echo Checking for X-Mod-Pagespeed header
  echo $HTML_HEADERS | egrep -q 'X-Mod-Pagespeed|X-Page-Speed'
  check [ $? = 0 ]

  echo Checking for combined CSS URL
  EXPECTED='href="styles/yellow\.css+blue\.css+big\.css+bold\.css'
  EXPECTED="$EXPECTED"'\.pagespeed\.cc\..*\.css">'
  fetch_until "$URL?ModPagespeedFilters=combine_css,trim_urls" \
      "grep -ic $EXPECTED" 1

  echo Checking for combined CSS URL without URL trimming
  EXPECTED="href=\"$HTTPS_EXAMPLE_ROOT/"
  EXPECTED="$EXPECTED"'styles/yellow\.css+blue\.css+big\.css+bold\.css'
  EXPECTED="$EXPECTED"'\.pagespeed\.cc\..*\.css">'
  fetch_until "$URL?ModPagespeedFilters=combine_css" "grep -ic $EXPECTED" 1
fi

# This filter convert the meta tags in the html into headers.
test_filter convert_meta_tags
run_wget_with_args $URL

echo Checking for Charset header.
grep -qi "CONTENT-TYPE: text/html; *charset=UTF-8" $WGET_OUTPUT
check [ $? = 0 ]

# This filter loads below the fold images lazily.
test_filter lazyload_images
check run_wget_with_args $URL
# Check src gets swapped with pagespeed_lazy_src
check fgrep -q "pagespeed_lazy_src=\"images/Puzzle.jpg\"" $FETCHED
check fgrep -q "pagespeed.lazyLoadInit" $FETCHED  # inline script injected

echo Testing whether we can rewrite javascript resources that are served
echo gzipped, even though we generally ask for them clear.  This particular
echo js file has "alert('Hello')" but is checked into source control in gzipped
echo format and served with the gzip headers, so it is decodable.  This tests
echo that we can inline and minify that file.
test_filter rewrite_javascript,inline_javascript with gzipped js origin
URL="$TEST_ROOT/rewrite_compressed_js.html"
QPARAMS="ModPagespeedFilters=rewrite_javascript,inline_javascript"
fetch_until "$URL?$QPARAMS" "grep -c Hello'" 1

echo Test that we can rewrite resources that are served with
echo Cache-Control: no-cache with on-the-fly filters.  Tests that the
echo no-cache header is preserved.
test_filter extend_cache with no-cache js origin
URL="$REWRITTEN_TEST_ROOT/no_cache/hello.js.pagespeed.ce.0.js"
echo run_wget_with_args $URL
run_wget_with_args $URL
cat $WGET_OUTPUT
cat $OUTDIR/hello.js.pagespeed.ce.0.js
check fgrep -q "'Hello'" $OUTDIR/hello.js.pagespeed.ce.0.js
check fgrep -q "no-cache" $WGET_OUTPUT

echo Test that we can rewrite Cache-Control: no-cache resources with
echo non-on-the-fly filters.
test_filter rewrite_javascript with no-cache js origin
URL="$REWRITTEN_TEST_ROOT/no_cache/hello.js.pagespeed.jm.0.js"
echo run_wget_with_args $URL
run_wget_with_args $URL
check fgrep -q "'Hello'" $OUTDIR/hello.js.pagespeed.jm.0.js
check fgrep -q "no-cache" $WGET_OUTPUT

# Checks that defer_javascript injects 'pagespeed.deferJs' from defer_js.js,
# but strips the comments.
test_filter defer_javascript optimize mode
echo run_wget_with_args $URL
check run_wget_with_args $URL
grep pagespeed.deferJs $FETCHED >/dev/null
check [ $? = 0 ]
grep text/psajs $FETCHED >/dev/null
check [ $? = 0 ]
grep '/\*' $FETCHED >/dev/null
check [ $? = 1 ]

# Checks that defer_javascript,debug injects 'pagespeed.deferJs' from
# defer_js.js, but retains the comments.
test_filter defer_javascript,debug optimize mode
FILE=defer_javascript.html?ModPagespeedFilters=$FILTER_NAME
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
check run_wget_with_args "$URL"
grep pagespeed.deferJs $FETCHED >/dev/null
check [ $? = 0 ]
grep text/psajs $FETCHED >/dev/null
check [ $? = 0 ]
grep '/\*' $FETCHED >/dev/null
check [ $? = 0 ]

# Checks that lazyload_images injects compiled javascript from
# lazyload_images.js.
test_filter lazyload_images optimize mode
echo run_wget_with_args $URL
check run_wget_with_args $URL
grep pagespeed.lazyLoad $FETCHED >/dev/null
check [ $? = 0 ]
grep '/\*' $FETCHED >/dev/null
check [ $? = 1 ]

# Checks that lazyload_images,debug injects non compiled javascript from
# lazyload_images.js
test_filter lazyload_images,debug debug mode
FILE=lazyload_images.html?ModPagespeedFilters=$FILTER_NAME
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
check run_wget_with_args "$URL"
grep pagespeed.lazyLoad $FETCHED >/dev/null
check [ $? = 0 ]
grep '/\*' $FETCHED >/dev/null
check [ $? = 0 ]

# Checks that inline_preview_images injects compiled javascript
test_filter inline_preview_images optimize mode
FILE=delay_images.html?ModPagespeedFilters=$FILTER_NAME
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
echo run_wget_with_args $URL
fetch_until $URL 'grep -c pagespeed.delayImagesInit' 1
fetch_until $URL 'grep -c /\*' 0
check run_wget_with_args $URL

# Checks that inline_preview_images,debug injects from javascript
# in non-compiled mode
test_filter inline_preview_images,debug debug mode
FILE=delay_images.html?ModPagespeedFilters=$FILTER_NAME
URL=$EXAMPLE_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
fetch_until $URL 'grep -c pagespeed.delayImagesInit' 3
check run_wget_with_args $URL

# Checks that local_storage_cache injects optimized javascript from
# local_storage_cache.js, adds the pagespeed_lsc_ attributes, inlines the data
# (if the cache were empty the inlining wouldn't make the timer cutoff but the
# resources have been fetched above).
test_filter local_storage_cache,inline_css,inline_images optimize mode
fetch_until $URL  'grep -c pagespeed.localStorageCacheInit()' 1
echo run_wget_with_args "$URL"
check run_wget_with_args "$URL"
check grep -q "pagespeed.localStorageCacheInit()" $FETCHED
check [ `grep -c ' pagespeed_lsc_url=' $FETCHED` = 2 ]
check grep -q "yellow {background-color: yellow" $FETCHED
check grep -q "<img src=\"data:image/png;base64" $FETCHED
check grep -q "<img .* alt=\"A cup of joe\"" $FETCHED
check_not grep -q "/\*" $FETCHED

# Checks that local_storage_cache,debug injects debug javascript from
# local_storage_cache.js, adds the pagespeed_lsc_ attributes, inlines the data
# (if the cache were empty the inlining wouldn't make the timer cutoff but the
# resources have been fetched above).
test_filter local_storage_cache,inline_css,inline_images,debug debug mode
fetch_until $URL  'grep -c pagespeed.localStorageCacheInit()' 1
echo run_wget_with_args "$URL"
check run_wget_with_args "$URL"
check grep -q "pagespeed.localStorageCacheInit()" $FETCHED
check [ `grep -c ' pagespeed_lsc_url=' $FETCHED` = 2 ]
check grep -q "yellow {background-color: yellow" $FETCHED
check grep -q "<img src=\"data:image/png;base64" $FETCHED
check grep -q "<img .* alt=\"A cup of joe\"" $FETCHED
check grep -q "/\*" $FETCHED

# Checks that local_storage_cache doesn't send the inlined data for a resource
# whose hash is in the magic cookie. First get the cookies from prior runs.
HASHES=$(grep "pagespeed_lsc_hash=" $FETCHED |\
         sed -e 's/^.*pagespeed_lsc_hash=.//' |\
         sed -e 's/".*$//')
HASHES=$(echo "$HASHES" | tr '\n' ',' | sed -e 's/,$//')
check [ -n "$HASHES" ]
COOKIE="Cookie: _GPSLSC=$HASHES"
# Check that the prior run did inline the data.
check grep -q "background-color: yellow" $FETCHED
check grep -q "src=.data:image/png;base64," $FETCHED
check grep -q "alt=.A cup of joe." $FETCHED
# Fetch with the cookie set.
test_filter local_storage_cache,inline_css,inline_images cookies set
echo "$WGET_PREREQ --save-headers --no-cookies --header \"$COOKIE\" $URL"
check $WGET_PREREQ --save-headers --no-cookies --header "$COOKIE" $URL
# Check that this run did NOT inline the data.
check_not fgrep "yellow {background-color: yellow" $FETCHED
check_not grep "src=.data:image/png;base64," $FETCHED
# Check that this run inserted the expected scripts.
check grep -q "pagespeed.inlineCss(.http://.*/styles/yellow.css.);" $FETCHED
check grep -q "pagespeed.inlineImg(.http://.*/images/Cuppa.png.," \
              ".alt=A cup of joe.," \
              ".alt=A cup of joe.," \
              ".alt=A cup of joe.s ..joe...," \
              ".alt=A cup of joe.s ..joe...);" $FETCHED

# Test flatten_css_imports.

# Fetch with the default limit so our test file is inlined.
test_filter flatten_css_imports,rewrite_css default limit
# Force the request to be rewritten with all applicable filters.
WGET_ARGS="${WGET_ARGS} --header=X-PSA-Blocking-Rewrite:psatest"
echo run_wget_with_args $URL
check run_wget_with_args $URL
check_not grep @import.url $FETCHED
check grep -q "yellow.background-color:" $FETCHED

# Fetch with a tiny limit so no file can be inlined.
test_filter flatten_css_imports,rewrite_css tiny limit
WGET_ARGS="${WGET_ARGS} --header=ModPagespeedCssFlattenMaxBytes:5"
# Force the request to be rewritten with all applicable filters.
WGET_ARGS="${WGET_ARGS} --header=X-PSA-Blocking-Rewrite:psatest"
echo run_wget_with_args $URL
check run_wget_with_args $URL
check grep -q @import.url $FETCHED
check_not grep "yellow.background-color:" $FETCHED

# Fetch with a medium limit so any one file can be inlined but not all of them.
test_filter flatten_css_imports,rewrite_css medium limit
WGET_ARGS="${WGET_ARGS} --header=ModPagespeedCssFlattenMaxBytes:50"
# Force the request to be rewritten with all applicable filters.
WGET_ARGS="${WGET_ARGS} --header=X-PSA-Blocking-Rewrite:psatest"
echo run_wget_with_args $URL
check run_wget_with_args $URL
check grep -q @import.url $FETCHED
check_not grep "yellow.background-color:" $FETCHED

# Ensure an EVEN number of tests because later tests depend on the value
# of $filter_spec_method and it flips between 'query_params' and 'headers'.
test_filter flatten_css_imports,rewrite_css medium limit

# Cleanup
rm -rf $OUTDIR
echo "PASS."
