FROM perl:latest

WORKDIR /opt/guaclite

COPY . .

RUN cpanm --installdeps .

ENTRYPOINT ["perl", "script/guaclite", "daemon"]

