#!/usr/bin/env python3

import sys, os, boto3, io, gzip, json, datetime, operator, random

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
            # @kelner: I'm not sure if this is necessary, the user may not want to
            # create a directory structure that mimics a DD archive structure
            # and we can't assume that the user will always have the same structure
            # it's better to just list all objects and let the script rebuild the
            # structure based on the datetime fields and rebuild the directory
            # path on the target bucket
            # if re.match( r".*dt=.*/hour=.*/archive_.*\..*\..*\.json\.gz", item_[ "Key" ] ) :
            #     if len( re.findall( "dt=" + date_filter + "/hour=" , item_[ "Key" ] ) ) > 0 :
            #         if len( re.findall( "/hour=" + hour_filter + "/archive_" , item_[ "Key" ] ) ) > 0 :
            #             list_.append( item_[ "Key" ] )
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

        # @kelner: DD rehydration expects a file with the format of
        # archive_225212.0418.3cq4YGouR1CeXmZR0FZqIQ.json.gz
        # where _225212.0418.3cq4YGouR1CeXmZR0FZqIQ can be any string
        # if just `archive.json.gz` is used, the rehydration will fail to find
        # any logs to rehydrate
        first_ran = random.randrange(100000,999999)
        second_ran = random.randrange(1000,9999)
        third_ran = ''.join(random.choice("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") for i in range(22))
        archive_name = "archive_" + str(first_ran) + "." + str(second_ran) + "." + str(third_ran) + ".json.gz"

        for line in text_.splitlines() :
            if json.loads( line ) :
                json_ = json.loads( line )
                # @kelner: this isn't the most DRY logic, some repetition here
                # TODO: refactor to be more DRY
                if "attributes" in json_ :
                    if "@timestamp" in json_["attributes"] :
                        del json_[ "attributes" ][ "@timestamp" ]
                    if "timestamp" in json_["attributes"] :
                        del json_[ "attributes" ][ "timestamp" ]
                    if "time" in json_["attributes"] :
                        del json_[ "attributes" ][ "time" ]
                    if "original_timestamp" in json_["attributes"] :
                        original_timestamp = json_[ "attributes" ][ "original_timestamp" ]
                        del json_[ "attributes" ][ "original_timestamp" ]

                        # checks for nanosecond epoch strings - came from customer using nanosecond epoch
                        # example: 1718774683182501000
                        # TODO: add more logic for other formats
                        if len(str(original_timestamp)) > 18 and str(original_timestamp).isdigit():
                            ns_dt = datetime.datetime.fromtimestamp(int(original_timestamp) // 1000000000)
                            original_timestamp = ns_dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")


                        if "date" in json_["attributes"] :
                            json_.update( { "date" : str(original_timestamp) } )
                        else :
                            json_[ "date" ] = str(original_timestamp)
                        if "timestamp" in json_["attributes"] :
                            json_.update( { "timestamp" : str(original_timestamp) } )
                        else:
                            json_[ "timestamp" ] = str(original_timestamp)
                else :
                    if "@timestamp" in json_ :
                        del json_[ "@timestamp" ]
                    if "timestamp" in json_ :
                        del json_[ "timestamp" ]
                    if "time" in json_ :
                        del json_[ "time" ]
                    if "original_timestamp" in json_ :
                        original_timestamp = json_[ "original_timestamp" ]
                        del json_[ "original_timestamp" ]

                        # checks for nanosecond epoch strings - came from customer using nanosecond epoch
                        # example: 1718774683182501000
                        # TODO: add more logic for other formats
                        if len(str(original_timestamp)) > 18 and str(original_timestamp).isdigit():
                            ns_dt = datetime.datetime.fromtimestamp(int(original_timestamp) // 1000000000)
                            original_timestamp = ns_dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")

                        if "date" in json_ :
                            json_.update( { "date" : str(original_timestamp) } )
                        else :
                            json_[ "date" ] = str(original_timestamp)
                        if "timestamp" in json_ :
                            json_.update( { "timestamp" : str(original_timestamp) } )
                        else:
                            json_[ "timestamp" ] = str(original_timestamp)

                json_[ "@path" ] = datetime.datetime.strptime( str(json_[ "date" ]) , "%Y-%m-%dT%H:%M:%S.000Z" ).strftime( "dt=%Y%m%d/hour=%H/" + archive_name )
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
                # print( json.dumps( item_ ) )
                buffer_.append( json.dumps( item_ ) )
    buffer_ = sorted( list( set( buffer_ ) ) )
    body = gzip_str( "\n".join( buffer_ ) )
    boto3.client( "s3" ).put_object( Bucket = target_bucket , Key = path_ , Body = body )
