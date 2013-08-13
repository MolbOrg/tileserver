#!/usr/bin/perl -w
use strict;
use warnings;
use DBI;
use Digest::MD5 qw(md5 md5_hex);
use Getopt::Long  qw(:config bundling);
use IO::Socket::INET;
use IO::Select;
use IO::BufferedSelect2;
use JSON;
use diagnostics;

=encoding utf8

=pod

=head1 NAME

=over

Tile server for Leaflet

=back

=cut

=head1 COMMAND LINE OPTIONS


 --server
        be a Leaflet tile server

 --host server_ip
        host address to bind to, default 127.0.0.1

 --port port_num
        host port listen on, default 8081

 --watchdog
        run server in watchdog mode (restart server if needed)

 --add
        collect tiles to sqlitedb

 --data directory
        directory for map data, default ./data

 --help,-h
    print usage, this help

 --test
 
    init_db();
    id_get_by_tid(8, 141,42);
    id_get_by_tid(1, 1, 0);
    tile_get_by_id(1, '2a');
    close_db();

=cut

=head1 EXAPMLES

  tileserver.pl --server --watchdog --host 127.0.0.1 --port 8081 --data ./data tile_path_tofile1 [tile_path_tofile2 ... ]
  cat filelist | tileserver.pl --server --watchdog --host 127.0.0.1 --port 8081 --data ./data

  tile file name must be in form  anyprefix/x/y/z/fname.png

=cut

=head1 METHODS

=over 12

=cut

my @cf_list_zoom_suffixes = ('z00', 'z01','z02','z03','z04','z05','z06','z07','z08','z09','z10','z11','z12','z13','z14');

my $cf_fname_tid2index = 'tiles_tid2index.sq';
my $cf_fname_md5 = 'tiles_uniq.sq';

my $cf_fname_tiles_prefix = 'tiles_';
my $cf_data_dir = './data';
my $cf_fc_max = 1000;
$cf_fc_max = 10000;

my $cf_host = '127.0.0.1';
my $cf_port = '8081';

my $cf_server = 0;
my $cf_add = 0;
my $cf_help = 0;
my $cf_test = 0;
my $cf_watchdog = 0;



GetOptions('host=s' => \$cf_host,
           'port=s' => \$cf_port,
           'data=s' => \$cf_data_dir,
           'server' => \$cf_server,
           'add' => \$cf_add,
           'h' => \$cf_help,
           'help' => \$cf_help,
           'test' => \$cf_test,
           'watchdog' => \$cf_watchdog
           );
sub usage
{
    print <<EOF;
GetOptions('host=s' => \$cf_host,
           'port=s' => \$cf_port,
           'data=s' => \$cf_data_dir,
           'server' => \$cf_server,
           'add' => \$cf_add,
           'h' => \$cf_help,
           'help' => \$cf_help
           );
    
EOF
    exit 0;
}

if($cf_watchdog)
{
    while(1)
    {
        my $arg = "--host $cf_host --port $cf_port --data $cf_data_dir --server";
        print "perl $0 $arg\n";
        `perl $0 $arg`;
    }
}

usage() if $cf_help;

my $cf_debug = {1 => 0,
             2 => 0,
             3 => 0,
             4 => 0,
             'flush' => 1,
             'cache_count' => 0,
#              'cache_del' => 10,
             'tile_store' => 0,
             'pack_tile' => 500,
             'cache_mishit' => 5,
             'db_index' => 0,
             'commit_tiles' => 1,
#              'cache_left' => 1
             };
my $cf_debug_each = {};
sub printdd
{
    my $d_id = shift;
    return if not exists $cf_debug->{$d_id};
    if($cf_debug->{$d_id} > 1)
    {
        $cf_debug_each->{$d_id} ++;
        if($cf_debug_each->{$d_id} >= $cf_debug->{$d_id})
        {
            $cf_debug_each->{$d_id} = 0;
            print 'skip(', $cf_debug->{$d_id}, '): ', @_;
        }
    }else{
        print @_ if $cf_debug->{$d_id};
    }
}


#keep 
#  map z/y/x -> id
#  map id -> map_part
#  map_part -- ca 100-200MB files to keep tile
#     id - data

=item C<init_db>

 open and read db's as necessary or create db's

=cut

my $db_tiles = {};
my $db_tiles_fc = {}; #items to flush
my $db_index;
my $db_index_fc = 0;
my $db_md5;
my $db_md5_fc = 0;
sub init_db
{

    #create or open tile files
    foreach my $s1 ('0'..'9', 'a'..'f')
    {
        foreach my $s2 ('0'..'9', 'a'..'f')
        {
            my $id = "$s1$s2";
            my $fname = "$cf_fname_tiles_prefix$id";
            my $dbfile = "$cf_data_dir/$fname";
            if(not -f $dbfile)
            {
                #create
                my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","", {RaiseError => 1, AutoCommit => 0});
                my $create_query = "CREATE TABLE tiles (id INTEGER PRIMARY KEY AUTOINCREMENT, tile BLOB)";
                my $create_query2 = "CREATE INDEX index_id ON tiles (id)";
                $dbh->do($create_query);
                $dbh->do($create_query2);
                $dbh->commit();
                $db_tiles->{$id} = $dbh;
            }else{
                my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","", {RaiseError => 1, AutoCommit => 0});
                $db_tiles->{$id} = $dbh;
            }
        }
    }
    #create or open index file
    my $dbfile = "$cf_data_dir/$cf_fname_tid2index";
    if(not -f $dbfile)
    {
        my $create_query = "CREATE TABLE tid2id (id INTEGER , db_id TEXT, z INTEGER, y INTEGER, x INTEGER, UNIQUE (z,y,x) ON CONFLICT IGNORE)";
        my $create_query2 = "CREATE INDEX index_tid ON tid2id (z, y, x)";
        my $create_query3 = "CREATE INDEX index_id ON tid2id (id, db_id)";
        $db_index = DBI->connect("dbi:SQLite:dbname=$dbfile","","", {RaiseError => 1, AutoCommit => 0});
        $db_index->do($create_query);
        $db_index->do($create_query2);
        $db_index->do($create_query3);
        $db_index->commit();
    }else{
        $db_index = DBI->connect("dbi:SQLite:dbname=$dbfile","","", {RaiseError => 1, AutoCommit => 0});
    }
    if(not defined $db_index)
    {
        warn "fail to open or create db: $dbfile\n";
        exit 0;
    }
    
    $dbfile = "$cf_data_dir/$cf_fname_md5";
    if(not -f $dbfile)
    {
        my $create_query = "CREATE TABLE md5list (id INTEGER, md5hex TEXT UNIQUE ON CONFLICT IGNORE)";
        my $create_query2 = "CREATE INDEX index_md5list ON md5list (md5hex)";
        $db_md5 = DBI->connect("dbi:SQLite:dbname=$dbfile","","", {RaiseError => 1, AutoCommit => 0});
        $db_md5->do($create_query);
        $db_md5->do($create_query2);
        $db_md5->commit();
    }else{
        $db_md5 = DBI->connect("dbi:SQLite:dbname=$dbfile","","", {RaiseError => 1, AutoCommit => 0});
    }
    if(not defined $db_md5)
    {
        warn "fail to open or create db: $dbfile\n";
        exit 0;
    }
}

=item C<close_db()>

 just flush and close db's

=cut
sub close_db
{
    foreach my $kk (keys %{$db_tiles})
    {
        my $dbh = $db_tiles->{$kk};
        $dbh->commit();
        $dbh->disconnect();
    }
    $db_index->commit();
    $db_index->disconnect();
    $db_md5->commit();
    $db_md5->disconnect();
}

#small cache to catch empty tile
#test add remove from cache
#resturn 1 if exists in cache or in tile files
my $cache = {};
my $cache_maxcount = 100;
my $cache_maxdelta = 50;
my $cache_stat_miss = 0;
my $cache_stat_hit = 0;
my $cache_stat_hit_db = 0;
my $cf_cache_print_stat = 50;
my $cache_print_stat = $cf_cache_print_stat;

=item C<cache_add($md5sum, $id)>

 cache tile for future use

=cut

sub cache_add
{
    my($md5sum, $id) = @_;
    if(not exists $cache->{'md'}->{$md5sum})
    {
        $cache->{'_count'} = 0 if not exists $cache->{'_count'};
        $cache->{'_count'}++;
        $cache->{'md'}->{$md5sum}->{'count'} = 1;
        $cache->{'md'}->{$md5sum}->{'id'} = $id;
        $cache->{'md'}->{$md5sum}->{'s_time'} = time();
    }else{
        $cache->{'md'}->{$md5sum}->{'count'}++;
    }
    printdd 'cache_count', "cache_count: ", $cache->{'_count'}, "\n";
    if($cache->{'_count'} > $cache_maxcount)
    {
        #remove
        my $tt = time();
        my @m = sort { $cache->{'md'}->{$b}->{'count'}/(1 + $tt - $cache->{'md'}->{$b}->{'s_time'}) <=> $cache->{'md'}->{$a}->{'count'}/(1 + $tt - $cache->{'md'}->{$a}->{'s_time'}) }
                        keys %{$cache->{'md'}};
        for(my $i = 0; $i < $cache_maxdelta and $#m > 0; $i++)
        {
            my $k = pop @m;
            printdd 'cache_del', "delete $k , ", $cache->{'md'}->{$k}->{'count'}, "  left ", $#m, "\n";
            delete $cache->{'md'}->{$k};
            $cache->{'_count'}--;
        }
         my $mindex = scalar @m;
         my $ccc = 0;
         foreach my $k (@m)
         {
             printdd 'cache_left', "$k  ", $cache->{'md'}->{$k}->{'count'}, "\n";
             select undef,undef,undef, 0.01;
             $mindex --;
             $ccc++;
             last if $ccc > 10;
         }
    }
}

=item C<cache_add($z, $y, $x, $db_id, $md5sum)>

 check tile for duplicate

=cut

sub cache_md5test
{
    my ($z, $y, $x, $db_id, $md5sum) = @_;
    my $dup = undef;
    if( exists $cache->{'md'}->{$md5sum})
    {
        $dup = $cache->{'md'}->{$md5sum}->{'id'};
        $cache->{'md'}->{$md5sum}->{'count'} ++;
        $cache_stat_hit ++;
    }else{
        $dup = ${$db_md5->selectall_arrayref("SELECT id FROM md5list WHERE md5hex='$md5sum' LIMIT 1")}[0][0];
        if(defined $dup)
        {
            $cache_stat_hit_db ++;
            cache_add($md5sum, $dup);
        }else{
            $cache_stat_miss++;
        }
    }
    if($cache_print_stat)
    {
        $cache_print_stat--;
        if($cache_print_stat < 1)
        {
            $cache_print_stat = $cf_cache_print_stat;
            printdd 'cache_mishit', "cache miss/hit/hitdb : $cache_stat_miss/$cache_stat_hit/$cache_stat_hit_db\n";
        }
    }
    return $dup;
}

=item C<tile_store($z, $y, $x, $blob)>

 add tile to db, check uniq

=cut

sub tile_store
{
    my ($z, $y, $x, $blob) = @_;
    my $md5sum = md5_hex($blob);
#     my $db_id = hex(substr($md5sum, 0, 2));
    my $db_id = substr($md5sum, 0, 2);
#     print "tile store: $z, $y, $x, $db_id, $md5sum\n";
    my $dup = cache_md5test($z, $y, $x, $db_id, $md5sum);
    my $tile_id;
    
    if($dup)
    {
        #tile exists, get id
        $tile_id = $dup;
    }else{
        #tile not exists add
        #CREATE TABLE tiles (id INTEGER PRIMARY KEY AUTOINCREMENT, tile BLOB)
        my $dbh = $db_tiles->{$db_id};
        my $sth = $dbh->prepare("INSERT INTO tiles(tile) VALUES (?)");
        $sth->bind_param(1, $blob, DBI::SQL_BLOB);
        $sth->execute();
        $sth->finish();
        $tile_id = $dbh->sqlite_last_insert_rowid();
        cache_add($md5sum, $tile_id);
        $db_tiles_fc->{$db_id}++;
        $db_tiles_fc->{'_total'} ++;
        if($db_tiles_fc->{$db_id} >= $cf_fc_max 
           or ($db_tiles_fc->{'_total'} > 10 * $cf_fc_max and $db_tiles_fc->{$db_id} >= $cf_fc_max * 0.1))
        {
            printdd 'commit_tiles', "commit_t : total(", $db_tiles_fc->{'_total'}, "), $db_id ", $db_tiles_fc->{$db_id}, "\n";
            $dbh->commit();
            $db_tiles_fc->{'_total'} -= $db_tiles_fc->{$db_id};
            $db_tiles_fc->{$db_id} = 0;
        }
        #keep md5list fresh
        $sth = $db_md5->prepare("INSERT INTO md5list (id, md5hex) VALUES(?, ?)");
        $sth->execute($tile_id, $md5sum);
        $sth->finish();
        $db_md5_fc++;
        if($db_md5_fc >= $cf_fc_max)
        {
            $db_md5->commit();
            $db_md5_fc = 0;
        }
    }
    printdd 'tile_store', "Tile store: $db_id, $tile_id\n";
    return ($db_id, $tile_id);
}

=item C<pack_tile($z, $y, $x, $fname)>

 put tile by file to db

=cut

sub pack_tile
{
    my ($z, $y, $x, $fname) = @_;
    printdd 'pack_tile', "pack: $z, $y, $x, $fname\n";
    my $blob;
    if(-f $fname)
    {
        open IMAGE, $fname or die "can't open image($fname): $!\n";

        my $buff;
        while(read IMAGE, $buff, 102400) {
            $blob .= $buff;
        }
        close IMAGE;
        my ($db_id, $tile_id) = tile_store($z, $y, $x,$blob);
        my $sth = $db_index->prepare("INSERT INTO tid2id (id, db_id, z, y, x) VALUES (?, ?, ?, ?, ?)");
        printdd 'db_index', "db_index: $tile_id, $db_id, $z, $y, $x\n";
        $sth->execute($tile_id, $db_id, $z, $y, $x);
        $sth->finish();
        $db_index_fc++;
        if($db_index_fc > $cf_fc_max)
        {
            $db_index->commit();
            $db_index_fc = 0;
        }
    }
}

=item C<tile_get_by_id($id, $db_id)>


=cut

sub tile_get_by_id
{
    my ($id, $db_id) = @_;
    return undef if not defined $id or not defined $db_id;
    
    my $sth = $db_tiles->{$db_id}->prepare('SELECT tile FROM tiles WHERE id=? LIMIT 1');
    $sth->execute($id);
    
    my $res = $sth->fetch();
    $sth->finish();
    
#     print  JSON->new->utf8(0)->pretty(0)->encode($res), "\n";
    return $res->[0];
}

=item C<id_get_by_tid($z, $y, $x)>


=cut

sub id_get_by_tid
{
    my ($z, $y, $x) = @_;
    my ($id, $db_id) = (undef, undef);
    
    my $sth = $db_index->prepare("SELECT id, db_id FROM tid2id WHERE z=? and y=? and x=? LIMIT 1");
    $sth->execute($z,$y, $x);
    my $res = $sth->fetchall_arrayref();
    $sth->finish();
    print  JSON->new->utf8(0)->pretty(0)->encode($res), "\n";
    if(scalar @$res)
    {
        print "result:", $res->[0][0], " ", $res->[0][1], "\n";
        $id = $res->[0][0];
        $db_id = $res->[0][1];
    }
    return ($id ,$db_id);
}

=item C<get_tile($z, $y, $x)>

 get tile by z/y/x

=cut

sub get_tile
{
    my ($z, $y, $x) = @_;
    my ($id , $db_id) = id_get_by_tid($z, $y, $x);
    my $tile = undef;
    
    if(not defined $id)
    {
    #TODO: try to scale previous zoom level
    }else{
        $tile = tile_get_by_id($id, $db_id);
    }
    print "get_tile: ", defined $tile ? 1 : -1, "\n";
    return $tile;
}

=item C<extract_tile(z,y,x,path)>

 extract tile by z/y/x to path/z/y/x.png
 TODO

=cut

sub extract_tile
{
}

=item C<main_add_tiles>

 tile file names from ARGV or from STDIN, add them to db

=cut

sub main_add_tiles
{
    init_db();
    if(scalar @ARGV)
    {
        foreach my $name (@ARGV)
        {
            my @ta = split("/", $name);
            if(scalar @ta >= 3)
            {
                my $fname = pop @ta;
                my $y = int(pop @ta);
                my $z = int(pop @ta);
                my $x;
                if($fname =~ /([0-9]+)[.]png/)
                {
                    $x = int($1);
                }
                if(defined $x and defined $y and defined $z)
                {
                    pack_tile($z, $y, $x, $name);
                }else{
                    print "not defined x,y,z: ", join("+", @ta), "\n";
                }
            }
        }
    }else{
        while(<>)
        {
            my $name = $_;
            chomp $name;
            my @ta = split("/", $name);
            if(scalar @ta >= 3)
            {
                my $fname = pop @ta;
                my $y = int(pop @ta);
                my $z = int(pop @ta);
                my $x;
                if($fname =~ /([0-9]+)[.]png/)
                {
                    $x = int($1);
                }
                if(defined $x)
                {
                    pack_tile($z, $y, $x, $name);
                }
            }
        }
    }

    close_db();
}

my $server = {};

=item C<init_server()>

 start listen

=cut

sub init_server
{
    init_db();
    my $socket = new IO::Socket::INET (
        LocalHost => $cf_host,
        LocalPort => $cf_port,
        Proto => 'tcp',
        Listen => 5,
        Reuse => 1
        ) or die "ERROR in Socket Creation : $!\n";

    my $select = IO::Select->new($socket) or die "IO::Select $!";
    
    $server->{'l_select'} = $select;
    $server->{'l_socket'} = $socket;
    $server->{'c_select'} =  IO::BufferedSelect2->new();
}

=item C<stop_server()>


=cut

sub stop_server
{
    close_db();
    $server->{'l_select'}->remove($server->{'l_socket'});
    shutdown($server->{'l_socket'}, 2);
}

=item C<send_to_client($fh, $image)>


=cut

sub send_to_client
{
    my ($fh, $image) = @_;
    print "==send_to_client=", defined $image ? length($image) : "not defined", "";
    if(not defined $image)
    {
        my $response_not = <<EOF;
HTTP/1.1 404 Not Found
Server: Eco Tiles
Content-Length: 14
Connection: close
Content-Type: text/html; charset=iso-8859-1

404 Not Found
EOF
        print $fh $response_not;
    }else{
        my $response_ok = "HTTP/1.1 200 OK\n";
        $response_ok .= "Server: Eco Tiles\n";
        $response_ok .= "Accept-Ranges: bytes";
        $response_ok .= "Content-Length: ".length($image)."\n";
        $response_ok .= "Connection: close\n";
        $response_ok .= "Content-Type: image/png\n\n";
        $response_ok .= $image;
        print $fh $image;
    }
    print "sended\n";
}

my $client = {};

=item C<parse_client($fh, $line)>


=cut

sub parse_client
{
    my ($fh, $line) = @_;
    my $h = {
        'GET' => '^GET[ ]+(.+) +HTTP/(.+)$',
        'Connection' => 'Connection: (.+)$',
    };
    
    if($line =~ /$h->{'GET'}/)
    {
        my $url = $1;
        my $http_v = $2;
        my $match_tile = '/tiles/([0-9]+)/([0-9]+)/([0-9]+).png';
        if($url =~ /$match_tile/)
        {
            my ($z, $y, $x) = (int($1), int($2), int($3));
            print "request $z, $y, $x tile\n";
            $client->{$fh} = {'x' => $x, 'y' => $y, 'z' => $z};
            send_to_client($fh, get_tile($z, $y, $x));
            remove_client($fh, 1);
        }else{
            remove_client($fh, 1); #remove and close at once
            delete $client->{$fh} if exists $client->{$fh};
        }
    }
}

=item C<remove_client($fh, $close)>

 remove $fh from select and watch lists, close if $close

=cut

sub remove_client
{
    my $fh = shift;
    my $close = shift;
    $server->{'c_select'}->remove($fh);
    $server->{'c_count'}--;
    close($fh) if defined $close;
    print "close\n"
}

my $cf_server_max_at_once = 20;
my $cf_server_max_requests = 100;

=item C<read_server()>


=cut

sub read_server
{
    my $s = $server->{'l_select'};
    
    #accept
    for(my $k = 0; $k <= $cf_server_max_at_once; $k++)
    {
        my $new = 0;
        foreach my $ss ($s->can_read(0))
        {
            my $new_connect = $ss->accept();
            $server->{'c_select'}->add($new_connect);
            $server->{'c_count'} ++;
            print "accept\n";
            $new = 1;
        }
        last if $new != 1;
    }
    #read and remove closed
    foreach my $bs_line ($server->{'c_select'}->read_line(0))
    {
        my ($fh, $line) = @$bs_line;
        if(not defined $line)
        {
            remove_client($fh);
        }else{
            print $line;
            parse_client($fh, $line);
        }
    }
}

=item C<main_tile_server()>

 read server loop with 0.05 sec sleep time and dot showing the hard work

=cut

sub main_tile_server
{
    init_server();
    local $| = 1;
    while(1)
    {
        print ".";
        read_server();
        select undef,undef,undef, 0.05;
    }
}

if($cf_add)
{
    main_add_tiles();
}
if($cf_server)
{
    main_tile_server();
}
if($cf_test)
{
    init_db();
    id_get_by_tid(8, 141,42);
    id_get_by_tid(1, 1, 0);
    tile_get_by_id(1, '2a');
    close_db();
}
