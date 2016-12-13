FROM perl:latest

COPY diff.pl /usr/src/myapp/diff.pl

# Install dependencies
RUN cpanm --notest Mojo::UserAgent \
	Text::Diff \
	Data::Dumper \
	Data::TreeDumper \
	Time::HiRes

# The command that will run when this is started
ENTRYPOINT [ "perl", "/usr/src/myapp/diff.pl" ]
