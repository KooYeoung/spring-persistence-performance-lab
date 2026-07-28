FROM amazoncorretto:21.0.11-al2023 AS build

WORKDIR /workspace
COPY gradlew gradlew.bat settings.gradle build.gradle ./
COPY gradle ./gradle
COPY src ./src
RUN ./gradlew --no-daemon --max-workers=1 bootJar

FROM amazoncorretto:21.0.11-al2023

RUN yum -y install shadow-utils curl tar gzip procps-ng findutils && yum clean all

RUN useradd --create-home --uid 10001 app
WORKDIR /app

COPY --from=build /workspace/build/libs/*.jar /app/app.jar
COPY scripts/exp-001/profiler/container/exp001-profile.sh /opt/exp001/exp001-profile.sh
RUN chmod 0755 /opt/exp001/exp001-profile.sh && chown app:app /app /opt/exp001/exp001-profile.sh

USER app

ENV SPRING_PROFILES_ACTIVE=exp001
ENV SERVER_PORT=8080
ENV JAVA_TOOL_OPTIONS="-Xms2g -Xmx2g -XX:+UseG1GC -Duser.timezone=UTC"

ENTRYPOINT ["/opt/exp001/exp001-profile.sh"]
CMD ["run-app"]
