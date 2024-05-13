#!/bin/bash
curl() {
    # https://docs.datadoghq.com/api/v1
    . secrets.ini &&
    /usr/bin/curl -qs                                       \
        --header "Content-Type: application/json"           \
        --header "DD-API-KEY: ${DD_CLIENT_API_KEY}"         \
        --header "DD-APPLICATION-KEY: ${DD_CLIENT_APP_KEY}" \
        "${@}" -o /dev/null -w "%{http_code} %{time_total}\n"
}
random-message()       { diceware -d ' ' ; }
now-iso8601()          { gdate -u "+%Y-%m-%dT%H:%M:%S.%NZ" | cut -c1-23,30 ; }
now-epoch()            { gdate -d $( now-iso8601 ) "+%s" ; }
6-month-epoch()        { gdate -u -d "1970-07-01" "+%s" ; }
6-month-ago-epoch()    { echo $(( $(now-epoch) - 15638400 )) ; }
6-month-ago-iso8601()  { gdate -u "+%Y-%m-%dT%H:%M:%S.%NZ" -d @$( 6-month-ago-epoch ) | cut -c1-23,30 ; }
random-source() {
    case ${RANDOM:0:1} in
    0|1) echo nginx ;;
    2|3) echo redis ;;
    4|5) echo elasticsearch ;;
    6|7) echo postgresql ;;
    8|9) echo aws ;;
    esac
}
random-env() {
    case ${RANDOM:0:1} in
    0|1) echo dev ;;
    2|3) echo int ;;
    4|5) echo staging ;;
    6|7) echo prod ;;
    8|9) echo sandbox ;;
    esac
}
random-service() {
    case ${RANDOM:0:1} in
    0|1) echo checkout ;;
    2|3) echo payment ;;
    4|5) echo web ;;
    6|7) echo db ;;
    8|9) echo cache ;;
    esac
}
random-provider() {
    case ${RANDOM:0:1} in
    0|1) echo aws ;;
    2|3) echo gcp ;;
    4|5) echo azure ;;
    6|7) echo alibaba ;;
    8|9) echo ovh ;;
    esac
}
random-region() {
    case ${RANDOM:0:1} in
    0|1) echo eu-west-1 ;;
    2|3) echo eu-east-1 ;;
    4|5) echo us-west-1 ;;
    6|7) echo us-east-1 ;;
    8|9) echo us-east-2 ;;
    esac
}
random-operation() {
    case ${RANDOM:0:1} in
    0|1) echo write ;;
    2|3) echo read ;;
    4|5) echo update ;;
    6|7) echo delete ;;
    8|9) echo create ;;
    esac
}
template() {
    ENV=$(random-env)
    SVC=$(random-service)
    PROV=$(random-provider)
    REGION=$(random-region)
    OP=$(random-operation)
    ID=$(echo $RANDOM|md5sum|cut -c1-8)
    cat << HEREDOC
{
    "ddsource": "$( random-source )",
    "ddtags": "env:$ENV,service:$SVC,provider:$PROV,region:$REGION,operation:$OP,id:$ID",
    "hostname": "$( diceware --no-caps -n 2 -d - )",
    "duration": "${RANDOM:0:1}.$RANDOM",
    "@timestamp": "$( now-iso8601 )",
    "original_timestamp": "$( 6-month-ago-iso8601 )",
    "message": "$( diceware -n 3 -d ' ' )",
    "env":"$ENV",
    "service":"$SVC",
    "provider":"$PROV",
    "region":"$REGION",
    "operation":"$OP",
    "id":"$ID"
}
HEREDOC
}
dd-ship-dummy-log() {
    # https://docs.datadoghq.com/api/v1/logs/#send-logs
    curl -X POST "https://http-intake.logs.datadoghq.com/v1/input" -d "$( template | jq -cr . )"
}

dd-ship-dummy-log
