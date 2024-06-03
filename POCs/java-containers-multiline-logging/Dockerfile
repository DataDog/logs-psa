FROM openjdk:22-ea-3-jdk-slim-bookworm

WORKDIR app

COPY multiline-poc/target/multiline-poc.jar multiline-poc.jar

EXPOSE 8080
ENTRYPOINT ["java","-jar","multiline-poc.jar"]
