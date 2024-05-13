#!/usr/bin/env python3

import sys, os, boto3, io, gzip, re, time, json, datetime, jinja2, operator

DEBUG = os.getenv("DEBUG")

def eprint(*args, **kwargs):
    if DEBUG == "true" :
        print(*args, file=sys.stderr, **kwargs)

try :
    if str( sys.argv[ 1 ] ) :
        source_bucket = str( sys.argv[ 1 ] )
except :
    eprint( "USAGE : python3 dd-rehydrate-past.py source_bucket destination_bucket" )
    exit( 128 )
try :
    if str( sys.argv[ 2 ] ) :
        target_bucket = str( sys.argv[ 2 ] )
except :
    eprint( "USAGE : python3 dd-rehydrate-past.py source_bucket destination_bucket" )
    exit( 128 )
try :
    if str( sys.argv[ 3 ] ) :
        date_filter = str( sys.argv[ 3 ] )
except :
    date_filter = ".*"
try :
    if str( sys.argv[ 4 ] ) :
        hour_filter = str( sys.argv[ 4 ] )
except :
    hour_filter = ".*"

def gzip_str( string_ ) :
    out = io.BytesIO()
    with gzip.GzipFile( fileobj=out, mode="w" ) as fo :
        fo.write( string_.encode() )
    bytes_obj = out.getvalue()
    return bytes_obj

def list_objects( bucket ) :
    list_ = []
    if "Contents" in boto3.client( "s3" ).list_objects_v2( Bucket = bucket ) :
        for item_ in boto3.client( "s3" ).list_objects_v2( Bucket = bucket )[ "Contents" ] :
            if re.match( r".*dt=.*/hour=.*/archive_.*\..*\..*\.json\.gz", item_[ "Key" ] ) :
                if len( re.findall( "dt=" + date_filter + "/hour=" , item_[ "Key" ] ) ) > 0 :
                    if len( re.findall( "/hour=" + hour_filter + "/archive_" , item_[ "Key" ] ) ) > 0 :
                        list_.append( item_[ "Key" ] )
        return( sorted( list_ , reverse = False ) )
    else:
        eprint( "TOTAL OBJECTS : 0" )
        exit()

def read_archives( bucket ) :
    buffer_ = []
    objects_list = list_objects( bucket )
    eprint( "TOTAL OBJECTS : " + str( len( objects_list ) ) )
    for object in objects_list :
        eprint( "READ s3://" + bucket + "/" + object )
        data_ = boto3.client( "s3" ).get_object( Bucket = bucket , Key = object )
        gzip_ = io.BytesIO( data_[ "Body" ].read() )
        text_ = gzip.GzipFile( None, "rb", fileobj=gzip_ ).read().decode( "utf-8" )
        eprint( "TEXT LINES COUNT : " + str( len( text_.splitlines() ) ) )
        for line in text_.splitlines() :
            if json.loads( line ) :
                json_ = json.loads( line )
                if "attributes" in json_ :
                    if "original_timestamp" in json_["attributes"] :
                        original_timestamp = json_[ "attributes" ][ "original_timestamp" ]
                        json_.update( { "date" : original_timestamp } )
                        del json_[ "attributes" ][ "original_timestamp" ]
                        del json_[ "attributes" ][ "@timestamp" ]
                        json_[ "@path" ] = datetime.datetime.strptime( json_[ "date" ] , "%Y-%m-%dT%H:%M:%S.000Z" ).strftime( "dt=%Y%m%d/hour=%H/archive.json.gz" )
                        buffer_.append( json_ )
    eprint( "PROCESSED LINES COUNT : " + str( len( buffer_ ) ) )
    return( sorted( buffer_ , key=operator.itemgetter( "date" ) , reverse = False ) )

data_ = read_archives( source_bucket )

targets_ = []
for item_ in data_ :
    targets_.append( item_[ "@path" ] )
targets_ = sorted( list( set( targets_ ) ) , reverse = False )

for path_ in targets_ :
    buffer_ = []
    eprint( "CREATING s3://" + target_bucket + "/" + path_ )
    for item_ in data_ :
        if "@path" in item_ :
            if item_[ "@path" ] == path_ :
                del item_[ "@path" ]
                print( json.dumps( item_ ) )
                buffer_.append( json.dumps( item_ ) )
    buffer_ = sorted( list( set( buffer_ ) ) )
    body = gzip_str( "\n".join( buffer_ ) )
    boto3.client( "s3" ).put_object( Bucket = target_bucket , Key = path_ , Body = body )
