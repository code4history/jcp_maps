#!/usr/local/bin/perl

use strict;
use warnings;

use File::Copy;
use XML::Simple;
use JSON qw/encode_json/;
use DBI qw(:sql_types);
use Digest::SHA1 qw(sha1_hex);
use File::Path;

opendir(my $dir, ".");
my @file = readdir($dir);
closedir($dir);

my $test    = 0;
my $workdir = '/tmp/jcp_maps/';
my $strgdir = '/mnt/s3rk/jcp_maps/';
my $diddir  = '/mnt/rrsrk/jcp_maps/did/';

unless (-e $workdir) { mkdir $workdir; }
unless (-e $strgdir) { mkdir $strgdir; }
unless (-e $diddir ) { mkdir $diddir;  }

open my $lh,">","processing.log";

foreach my $file (sort @file) {
    next unless ($file =~ /^(t[^\.]+\.jpg)\.([^\.]+)\.z([a-c])\.points/);
    my $jpgfile    = $1;
    my $placename  = $2;
    my $projection = $3;
    next if ($jpgfile eq 'txu-oclc-6534730.jpg');

    eval {
        print $lh "Processing $jpgfile ($placename) start...\n";

        open my $fh,"<",$file;
        open my $wh,">",$workdir.$jpgfile.".gcp";

        my @gcps;
        my @outlines;
        while (my $line=<$fh>) {
            my @devide = split(/,/,$line);
            next if ($devide[0] !~ /^\d/);
            if ($devide[0] =~ /^1111($|\.)/ && $devide[1] =~ /^1111($|\.)/) {
                push @outlines, [$devide[2],  $devide[3]*-1];
            } else {
                my   @gcp  = (@devide[0..2],$devide[3]*-1);
                push @gcps,  \@gcp;
                print $wh join(" ",@gcp)."\n";
            }
        }

        close $fh;
        close $wh;
        print $lh "Check GCPs end...\n";
        #move $file, $did.$file or die "Fail to move " . $did.$file;

        `python ./gcp2wld.py -i ${workdir}${jpgfile}.gcp > ${workdir}${jpgfile}w`;
        move $workdir.$jpgfile.".gcp", $diddir.$jpgfile.".gcp" or die "Fail to move " . $diddir.$jpgfile.".gcp";
        copy $jpgfile, $workdir.$jpgfile or die "Fail to copy " . $workdir.$jpgfile;
        print $lh "Generate world file end...\n";

        my $proj4 = sprintf('+proj=poly +lat_0=40.5 +lon_0=%d +x_0=914398.5307444408 +y_0=1828797.0614888816 +ellps=clrk66 +to_meter=0.9143985307444408 +no_defs',($projection eq 'a' ? 143 : $projection eq 'b' ? 135 : 127 ));
        `gdalwarp -srcnodata 0 -dstalpha -s_srs '${proj4}' -t_srs '+proj=longlat +ellps=clrk66 +datum=NAD27 +no_defs' ${workdir}${jpgfile} ${workdir}${placename}.tif`;
        move $workdir.$jpgfile."w", $diddir.$jpgfile."w" or die "Fail to move " . $diddir.$jpgfile."w";
        unlink $workdir.$jpgfile or die "Fail to remove " . $workdir.$jpgfile;
        print $lh "Create tokyo97 GeoTiff end...\n";

        my $title =  $placename;
        $title    =~ s/_/ /mg;
        $title    =  ucfirst($title);
        `python ./gdal2tiles.py -e -s '+proj=longlat +ellps=bessel +towgs84=-146.336,506.832,680.254' --url='http://t.tilemap.jp/jcp_maps/' -c 'Japan City Plans U.S. Army Map Service, 1945-1946. Courtesy of the University of Texas Libraries, The University of Texas at Austin, Tilemap.JP.' -t '${title}' -k -w none -z '11-16' -a 0 ${workdir}${placename}.tif ${workdir}${placename}`; 
        move $workdir.$placename.".tif", $diddir.$placename.".tif" or die "Fail to move " . $diddir.$placename.".tif";
        print $lh "Create map tile and xml, kml end...\n";

        my $dbfile = $workdir.$placename.".mbtiles";
        unlink $dbfile if (-e $dbfile);
        my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","");

        my @sqls = (
            'CREATE TABLE map ( zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_id TEXT, grid_id TEXT );',
            'CREATE TABLE grid_key ( grid_id TEXT, key_name TEXT );',
            'CREATE TABLE keymap ( key_name TEXT, key_json TEXT );',
            'CREATE TABLE grid_utfgrid ( grid_id TEXT, grid_utfgrid BLOB );',
            'CREATE TABLE images ( tile_data blob, tile_id text );',
            'CREATE TABLE metadata ( name text, value text );',
            'CREATE UNIQUE INDEX map_index ON map (zoom_level, tile_column, tile_row);',
            'CREATE UNIQUE INDEX grid_key_lookup ON grid_key (grid_id, key_name);',
            'CREATE UNIQUE INDEX keymap_lookup ON keymap (key_name);',
            'CREATE UNIQUE INDEX grid_utfgrid_lookup ON grid_utfgrid (grid_id);',
            'CREATE UNIQUE INDEX images_id ON images (tile_id);',
            'CREATE UNIQUE INDEX name ON metadata (name);',
            'CREATE VIEW tiles AS SELECT map.zoom_level AS zoom_level, map.tile_column AS tile_column, map.tile_row AS tile_row, images.tile_data AS tile_data FROM map JOIN images ON images.tile_id = map.tile_id;',
            'CREATE VIEW grids AS SELECT map.zoom_level AS zoom_level, map.tile_column AS tile_column, map.tile_row AS tile_row, grid_utfgrid.grid_utfgrid AS grid FROM map JOIN grid_utfgrid ON grid_utfgrid.grid_id = map.grid_id;',
            'CREATE VIEW grid_data AS SELECT map.zoom_level AS zoom_level, map.tile_column AS tile_column, map.tile_row AS tile_row, keymap.key_name AS key_name, keymap.key_json AS key_json FROM map JOIN grid_key ON map.grid_id = grid_key.grid_id JOIN keymap ON grid_key.key_name = keymap.key_name;'
        );

        foreach my $sql (@sqls) {
            my $sth = $dbh->prepare($sql);
            $sth->execute();
        }

        mkdir $strgdir.$placename unless (-e $strgdir.$placename);

        opendir(my $iddir, $workdir.$placename);
        my @zfiles = readdir($iddir);
        closedir($iddir);

        foreach my $zfile (sort @zfiles) {
            next if ($zfile =~ /^\.+$/);
            my $z      = $zfile;
            my $zfpath = $placename.'/'.$zfile;
            if ( -d $workdir.$zfpath ) {
                mkdir $strgdir.$zfpath unless (-e $strgdir.$zfpath);

                opendir(my $zdir, $workdir.$zfpath);
                my @xfiles = readdir($zdir);
                closedir($zdir);

                foreach my $xfile (sort @xfiles) {
                    next if ($xfile =~ /^\.+$/);
                    my $x      = $xfile;
                    my $xfpath = $zfpath.'/'.$xfile;
                    if ( -d $workdir.$xfpath ) {
                        mkdir $strgdir.$xfpath unless (-e $strgdir.$xfpath);

                        opendir(my $xdir, $workdir.$xfpath);
                        my @yfiles = readdir($xdir);
                        closedir($xdir);   

                        foreach my $yfile (sort @yfiles) {
                            next if ($yfile =~ /^\.+$/);
                            my $yfpath = $xfpath.'/'.$yfile;
                            if ($yfile =~ /^(\d+)\.png$/) {
                                my $y = $1;

                                my $img = `cat ${workdir}${yfpath}`;
                                my $hash = substr(sha1_hex($img),0,32);
                                my $sql = 'INSERT INTO images (tile_data,tile_id) VALUES (?,?);';
                                my $sth = $dbh->prepare($sql);
                                $sth->bind_param(1, $img, SQL_BLOB);
                                $sth->bind_param(2, $hash);
                                $sth->execute();
                                $sql    = 'INSERT INTO map ( zoom_level, tile_column, tile_row, tile_id) VALUES (?,?,?,?);';
                                $sth    = $dbh->prepare($sql);
                                $sth->execute($z,$x,$y,$hash);
                            }
                            copy $workdir.$yfpath, $strgdir.$yfpath or die "Fail to copy " . $strgdir.$yfpath;
                        }
                    } else {
                        copy $workdir.$xfpath, $strgdir.$xfpath or die "Fail to copy " . $strgdir.$xfpath;
                    }
                }
                print $lh "Analyze zoom level $zfile end...\n";
            } else {
                copy $workdir.$zfpath, $strgdir.$zfpath or die "Fail to copy " . $strgdir.$zfpath;
            }
        }
        print $lh "Analyze tile structure all end...\n";

        my $xmlref = XMLin($workdir.$placename."/tilemapresource.xml");
        my $bbox = $xmlref->{'BoundingBox'};
        my @tset = @{$xmlref->{'TileSets'}->{'TileSet'}};
        my $minz = $tset[0]->{'order'} + 0;
        my $maxz = $tset[$#tset]->{'order'} + 0;
        my $cent = int(($minz + $maxz) / 2);
        my $json = {
            scheme      => 'tms',
            basename    => $placename . '.mbtiles',
            id          => $placename,
            filesize    => 0,
            bounds      => [map {$bbox->{$_} + 0} qw/miny minx maxy maxx/],
            center      => [(map {($bbox->{"max$_"} + $bbox->{"min$_"})/2.0} qw/y x/),$cent],
            minzoom     => $minz,
            maxzoom     => $maxz,
            name        => $xmlref->{'Title'},
            description => 'Japan City Plans U.S. Army Map Service, 1945-1946.',
            attribution => 'Courtesy of the University of Texas Libraries, The University of Texas at Austin, Tilemap.JP.',
            legend      => '',
            version     => '1.0.0',
            template    => '',
            tiles       => ['http://t.tilemap.jp/jcp_maps/'.$placename.'/{z}/{x}/{y}.png'],
            grids       => [''],
            download    => 'http://t.tilemap.jp/jcp_maps/'.$placename.'.mbtiles'
        };

        my $sql = 'INSERT INTO metadata (name, value) VALUES (?,?);';
        my $sth = $dbh->prepare($sql);
        foreach my $jkey (qw/bounds center minzoom maxzoom name description attribution version template/) {
            my $data = $json->{$jkey};
            if (ref $data) { $data = join(",",@{$data}); }
            $sth->execute($jkey,$data);
        }
        $dbh->disconnect;

        $json->{filesize} = -s $workdir.$placename.".mbtiles";
        my $json_out = encode_json($json);
        open my $jh,">",$workdir.$placename.'.json';
        print $jh $json_out;
        close $jh;
        move $workdir.$placename.".json", $strgdir.$placename.".json" or die "Fail to move " . $strgdir.$placename.".json";
        print $lh "Create TileJSON end...\n";

        move $workdir.$placename.".mbtiles", $strgdir.$placename.".mbtiles" or die "Fail to move " . $strgdir.$placename.".mbtiles";
        print $lh "Create MBTiles end...\n";

        move $file, $diddir.$file or die "Fail to move " . $diddir.$file;
        move $jpgfile, $diddir.$jpgfile or die "Fail to move " . $diddir.$jpgfile;
        rmtree($workdir.$placename);
        print $lh "Move original files and clean working directories...\n";
    };
    if ($@) {
        print $lh "Processing $jpgfile ($placename) is failed due to: $@ \nPlease process it again later.\n\n";
    }

    if ($test || -e './stop') {
        unlink './stop';
        last;
    }
}

close $lh;

__END__
bc7895946c51947bc39e22d0f7c007ab
fed75c951d0e3b6391195403ab831441



{"scheme":"xyz","basename":"voorlichter_old.mbtiles","id":"voorlichter_old","filesize":982203392,"bounds":[140.0015,41.834,140.2484,41.9156],
"center":[140.1206,41.8658,15],"minzoom":12,"maxzoom":20,"name":"開陽","description":"数値地図（国土基本情報）江差や国土数値情報（バスルートデータ・バス停データ）を使用した試作地図","attribution":"この地図の作成に当たっては、国土地理院長の承認を得て、同院発行の数値地図（国土基本情報）を使用した。 (承認番号 平24情使、 第xx号) /国土数値情報（バスルートデータ ・バス停留所データ）国土交通省",
"legend":"<h2>凡例</h2>\n<a>準備中</a>","version":"1.0.0","template":"{{#__location__}}{{/__location__}}{{#__teaser__}}<table>\n<caption>建築物</caption>\n<tr><td>ID</td><td>{{{rID}}}</td></tr>\n<tr><td>種別</td><td>{{{type}}}</td></tr>\n</table>{{/__teaser__}}{{#__full__}}{{/__full__}}",
"tiles":["http://bulky.handygeospatial.info/v2/voorlichter_old/{z}/{x}/{y}.png","http://bulky2.handygeospatial.info/v2/voorlichter_old/{z}/{x}/{y}.png"],
"grids":["http://bulky.handygeospatial.info/v2/voorlichter_old/{z}/{x}/{y}.grid.json"],
"download":"http://bulky.handygeospatial.info/v2/voorlichter_old.mbtiles"}
