use v6;
use Test;
use DBIish;

plan 11;

my %con-parms = :database<dbdishtest>, :user<testuser>, :password<testpass>;
my $dbh;

try {
  $dbh = DBIish.connect('mysql', |%con-parms);
  CATCH {
	    when X::DBIish::LibraryMissing | X::DBDish::ConnectionFailed {
		diag "$_\nCan't continue.";
	    }
            default { .rethrow; }
  }
}
without $dbh {
    skip-rest 'prerequisites failed';
    exit;
}

ok $dbh,    'Connected';
my $subsec = $dbh.drv.version after v5.6.4;
my $field = 'TIMESTAMP'; $field ~= '(6)' if $subsec;
diag "Using $field";
lives-ok {
    $dbh.execute(qq|
    CREATE TEMPORARY TABLE test_datetime (
	adate DATE,
	atime TIME,
	atimestamp $field 
    )|);
}, 'Table created';

my $sth = $dbh.prepare('INSERT INTO test_datetime (adate, atimestamp) VALUES(?, ?)');
my $now = DateTime.now;
$now .= truncated-to('second') unless $subsec;
lives-ok {
    $sth.execute($now.Date, $now);
}, 'Insert Perl6 values';
$sth.dispose;
$sth = $dbh.prepare('SELECT adate, atimestamp FROM test_datetime');
my @coltype = $sth.column-types;
ok @coltype eqv [Date, DateTime],	    'Column-types';

is $sth.execute.rows, 1,			    'One row';
my ($date, $datetime) = $sth.row;
isa-ok $date, Date;
isa-ok $datetime,  DateTime;
is $date, $now.Date,			    'Today';
is $datetime, $now,			    'Right now';
$sth.dispose;
$sth = $dbh.prepare('SELECT NOW()');
is $sth.execute.rows, 1,			    'One now';
$datetime = $sth.row[0];
if $subsec {
    isnt $datetime, $now,		    'Server drift';
} else {
    skip "Without subsecond precision",  1;
}
diag $now.Instant - $datetime.Instant;
