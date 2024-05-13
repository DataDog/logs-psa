import json, urllib.parse, boto3, io, gzip, datetime

s3 = boto3.client("s3")


def gzip_str(string_):
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="w") as fo:
        fo.write(string_.encode())
    bytes_obj = out.getvalue()
    return bytes_obj


def lambda_handler(event, context):
    bucket = event["Records"][0]["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(
        event["Records"][0]["s3"]["object"]["key"], encoding="utf-8"
    )
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
        print("READ  s3://" + bucket + "/" + key)
        archive_name = key.split("/")[-1]
        body_str = (
            gzip.GzipFile(None, "rb", fileobj=io.BytesIO(response["Body"].read()))
            .read()
            .decode("utf-8")
        )
        buffer_ = []
        print("PARSE s3://" + bucket + "/" + key)
        for line in body_str.splitlines():
            json_ = json.loads(line)
            original_timestamp = json_["attributes"]["original_timestamp"]
            json_.update({"date": original_timestamp})
            del json_["attributes"]["original_timestamp"]
            del json_["attributes"]["@timestamp"]
            json_["@path"] = datetime.datetime.strptime(
                json_["date"], "%Y-%m-%dT%H:%M:%S.000Z"
            ).strftime("dt=%Y%m%d/hour=%H/{}".format(archive_name))
            # print( json.dumps( json_ , indent = 4 ) )
            print(json.dumps(json_))
            buffer_.append(json_)
        print("PROCESSED {} JSON log events".format(str(len(buffer_))))
        data_ = buffer_
        targets_ = []
        for item_ in data_:
            targets_.append(item_["@path"])
        targets_ = sorted(list(set(targets_)), reverse=False)
        print("MATCHED {} destination log archives".format(str(len(targets_))))
        print(targets_)
        target_bucket = "7c5fa03b"
        for path_ in targets_:
            buffer_ = []
            print("CREATING s3://" + target_bucket + "/" + path_)
            for item_ in data_:
                if "@path" in item_:
                    if item_["@path"] == path_:
                        del item_["@path"]
                        # print( json.dumps( item_ , indent = 4 ) )
                        print(json.dumps(item_))
                        buffer_.append(json.dumps(item_))
            buffer_ = sorted(list(set(buffer_)))
            body = gzip_str("\n".join(buffer_))
            boto3.client("s3").put_object(Bucket=target_bucket, Key=path_, Body=body)
            print("WROTE s3://" + target_bucket + "/" + path_)
        return
    except Exception as e:
        print(e)
        print(
            "Error getting object {} from bucket {}. Make sure they exist and your bucket is in the same region as this function.".format(
                key, bucket
            )
        )
        raise e
