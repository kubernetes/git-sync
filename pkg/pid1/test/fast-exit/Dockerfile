FROM debian
RUN apt-get update && apt-get install -y bash procps psmisc psutils
COPY fast-exit /fast-exit
ENTRYPOINT ["/fast-exit"]
