use v6;

need DBDish;

unit class DBDish::Pg::StatementHandle does DBDish::Role::StatementHandle;
use DBDish::Pg::Native;

has PGconn $!pg_conn;
has Str $!statement_name;
has $!statement;
has $!param_count;
has $.dbh;
has $!result;
has $!affected_rows;
has @!column_names;
has Int $!row_count;
has $!field_count;
has $!current_row = 0;

method !handle-errors {
    if $!result.is-ok {
        self!reset_errstr;
        True;
    }
    else {
        self!set_errstr($!result.PQresultErrorMessage);
        die self.errstr if $.RaiseError;
        Nil;
    }
}

method !munge_statement {
    my $count = 0;
    $!statement.subst(:g, '?', { '$' ~ ++$count});
}

submethod BUILD(:$!statement, :$!pg_conn, :$!statement_name, :$!param_count, :$!dbh) { }

method execute(*@params is copy) {
    $!current_row = 0;
    die "Wrong number of arguments to method execute: got @params.elems(), expected $!param_count" if @params != $!param_count;
    my @param_values := ParamArray.new;
    for @params.kv -> $k, $v {
        @param_values[$k] = ~$v;
    }

    $!result = $!pg_conn.PQexecPrepared($!statement_name, @params.elems, @param_values,
        Null, # ParamLengths, NULL pointer == all text
        Null, # ParamFormats, NULL pointer == all text
        0,    # Resultformat, 0 == text
    );

    self!handle-errors;
    $!row_count = $!result.PQntuples;

    my $rows = self.rows;
    $rows == 0 ?? "0E0" !! $rows;
}

# do() and execute() return the number of affected rows directly or:
# rows() is called on the statement handle $sth.
method rows() {
    without $!affected_rows {
        $!affected_rows = $!result.PQcmdTuples;
        self!handle-errors;
    }

    with $!affected_rows {
	+$_;
    }
}

method _row(:$hash) {
    my @row_array;
    my %ret_hash;
    return $hash ?? Hash !! Array if $!current_row >= $!row_count;

    unless defined $!field_count {
        $!field_count = $!result.PQnfields;
    }
    my @names = self.column_names if $hash;
    my @types = self.column_p6types;
    if $!result {
        self!reset_errstr;
        my $afield = False;
        for ^$!field_count {
            FIRST {
                $afield = True;
            }
            my $res := $!result.PQgetvalue($!current_row, $_);
            my $is-null = $!result.PQgetisnull($!current_row, $_);
            my $value;
            given (@types[$_]) {
                when 'Str' {
                  $value = $is-null ?? Str !! $res;
                }
                when 'Int' {
                  $value = $is-null ?? Int !! $res.Int;
                }
                when 'Bool' {
                  $value = $is-null ?? Bool !! self.true_false($res);
                }
                when 'Num' {
                  $value = $is-null ?? Num !! $res.Num;
                }
                when 'Rat' {
                  $value = $is-null ?? Rat !! $res.Rat;
                }
                when 'Real' {
                  $value = $is-null ?? Real !! $res.Real;
                }
                when 'Array<Int>' {
                  $value := _pg-to-array( $res, 'Int' );
                }
                when 'Array<Str>' {
                  $value := _pg-to-array( $res, 'Str' );
                }
                when 'Array<Num>' {
                  $value := _pg-to-array( $res, 'Num' );
                }
                when 'Array<Rat>' {
                  $value = _pg-to-array( $res, 'Rat' );
                }
                default {
                  $value = $res;
                }
            }
            $hash ?? (%ret_hash{@names[$_]} = $value) !! @row_array.push($value);
        }
        $!current_row++;
        self!handle-errors;

        if ! $afield { self.finish; }
    }
    $hash ?? %ret_hash !! @row_array;
}


method fetchrow() {
    my @row_array;
    return () if $!current_row >= $!row_count;

    unless defined $!field_count {
        $!field_count = $!result.PQnfields;
    }

    if $!result {
        self!reset_errstr;

        for ^$!field_count {
            my $res := $!result.PQgetvalue($!current_row, $_);
            if $res eq '' {
                $res := Str if $!result.PQgetisnull($!current_row, $_)
            }
            @row_array.push($res)
        }
        $!current_row++;
        self!handle-errors;

        if ! @row_array { self.finish; }
    }
    @row_array;
}

method column_names {
    $!field_count = $!result.PQnfields;
    unless @!column_names {
        for ^$!field_count {
            my $column_name = $!result.PQfname($_);
            @!column_names.push($column_name);
        }
    }
    @!column_names
}

# for debugging only so far
method column_oids {
    $!field_count = $!result.PQnfields;
    my @res;
    @res.push: $!result.PQftype($_) for ^$!field_count;
    @res;
}

method fetchall_hashref(Str $key) {
    my %results;

    return () if $!current_row >= $!row_count;

    while my $row = self.fetchrow_hashref {
        %results{$row{$key}} = $row;
    }

    my $results_ref = %results;
    $results_ref;
}

method column_p6types {
   my @types = self.column_oids;
   @types.map:{%oid-to-type-name{$_}};
}

my grammar PgArrayGrammar {
    rule array       { '{' (<element> ','?)* '}' }
    rule TOP         { ^ <array> $ }
    rule element     { <array> | <float> | <integer> | <string> }
    token float      { (\d+ '.' \d+) }
    token integer    { (\d+) }
    rule string      { '"' $<value>=( [\w|\s]+ ) '"' | $<value>=( \w+ ) }
};

sub _to-type($value, Str $type where $_ eq any([ 'Str', 'Num', 'Rat', 'Int' ])) {
  return $value unless $value.defined;
  if $type eq 'Str' {
      # String
      return ~$value;
  } elsif $type eq 'Num' {
      return Num($value);
  } elsif $type eq 'Rat' {
      # Floating point number
      return Rat($value);
  } else {
      # Must be Int
      return Int($value);
  }
}

sub _to-array(Match $match, Str $type where $_ eq any([ 'Str', 'Num', 'Rat', 'Int' ])) {
    my @array;
    for $match.<array>.values -> $element {
      if $element.values[0]<array>.defined {
          # An array
          push @array, _to-array( $element.values[0], $type );
      } elsif $element.values[0]<float>.defined {
          # Floating point number
          push @array, _to-type( $element.values[0]<float>, $type );
      } elsif $element.values[0]<integer>.defined {
          # Integer
          push @array, _to-type( $element.values[0]<integer>, $type );
      } else {
          # Must be a String
          push @array, _to-type( $element.values[0]<string><value>, $type );
      }
    }

    @array;
}

sub _pg-to-array(Str $text, Str $type where $_ eq any([ 'Str', 'Rat', 'Int' ])) {
    my $match = PgArrayGrammar.parse( $text );
    die "Failed to parse" unless $match.defined;
    _to-array($match, $type);
}


method pg-array-str(@data) {
  my @tmp;
  for @data -> $c {
    if  $c ~~ Array {
      @tmp.push(self.pg-array-str($c));
    } else {
      if $c ~~ Numeric {
        @tmp.push($c);
      } else {
         my $t = $c.subst('"', '\\"');
         @tmp.push('"'~$t~'"');
      }
    }
  }
  '{' ~ @tmp.join(',') ~ '}';
}

method true_false(Str $s) {
    $s eq 't';
}


method finish() {
    if $!result {
        $!result.PQclear;
        $!result       = Any;
        @!column_names = ();
    }
    Bool::True;
}

method !get_row {
    my @data;
    for ^$!field_count {
        @data.push: $!result.PQgetvalue($!current_row, $_);
    }
    $!current_row++;

    @data;
}