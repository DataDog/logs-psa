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
        first_rand = random.randrange(100000,999999)
        second_rand = random.randrange(1000,9999)
        third_rand = ''.join(random.choice("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") for i in range(22))
        archive_name = "archive_" + str(first_rand) + "." + str(second_rand) + "." + str(third_rand) + ".json.gz"

        for line in text_.splitlines() :
            if json.loads( line ) :
                json_ = json.loads( line )

                # if there are tags, make sure they are a list
                # if not a list, convert equal delimited string to list
                if "tags" in json_ :
                    tags = json_[ "tags" ]
                    try:
                        json.loads(tags)
                    except:
                        if type(tags) != list:
                            d = []
                            s = str(tags).split(",")

                            for item in s:
                                if "=" in item:
                                    i = item.split("=",1)
                                    d.append(i[0] + ':' + i[-1])
                                else:
                                    d.append(item)

                            #print(json.dumps(d))
                            del json_[ "tags" ]
                            json_["tags"] = d

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
                            original_timestamp = int(original_timestamp) // 1000000000
                            ns_dt = datetime.datetime.fromtimestamp(int(original_timestamp))
                            original_date = ns_dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")


                        if "date" in json_["attributes"] :
                            json_["attributes"].update( { "date" : str(original_date) } )
                        else :
                            json_["attributes"][ "date" ] = str(original_date)
                        if "timestamp" in json_["attributes"] :
                            json_["attributes"].update( { "timestamp" : int(original_timestamp) } )
                        else:
                            json_["attributes"][ "timestamp" ] = int(original_timestamp)
                else :
                    # add attributes
                    json_["attributes"] = {}

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
                            original_timestamp = int(original_timestamp) // 1000000000
                            ns_dt = datetime.datetime.fromtimestamp(int(original_timestamp))
                            original_date = ns_dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")

                        if "date" in json_ :
                            json_.update( { "date" : str(original_date) } )
                            json_["attributes"][ "date" ] = str(original_date)
                        else :
                            json_[ "date" ] = str(original_date)
                            json_["attributes"][ "date" ] = str(original_date)
                        if "timestamp" in json_ :
                            json_.update( { "timestamp" : int(original_timestamp) } )
                            json_["attributes"][ "timestamp" ] = int(original_timestamp)
                        else:
                            json_[ "timestamp" ] = int(original_timestamp)
                            json_["attributes"][ "timestamp" ] = int(original_timestamp)

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
