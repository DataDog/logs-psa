FROM openjdk:11

WORKDIR app

COPY multiline-poc/target/multiline-poc.jar multiline-poc.jar

EXPOSE 8080
ENTRYPOINT ["java","-jar","multiline-poc.jar"]
