package GuacLite::Client::Guacd;

use Mojo::Base 'Mojo::EventEmitter';

use Mojo::Util;
use Mojo::Promise;

use Carp ();
use Scalar::Util ();

use constant DEBUG => $ENV{MOJO_GUACDCLIENT_DEBUG};

has host => 'localhost';
has port => '4822';

# the following should probably all be required parameters, but for now, do this
has protocol => 'vnc';
has connection_args => sub { {} };

has width => 1024;
has height => 768;
has dpi => 96;

has audio_mimetypes => sub { [] };
has image_mimetypes => sub { [] };
has video_mimetypes => sub { [] };
has timezone => '';

sub close {
  my $self = shift;
  return unless my $s = $self->{stream};
  $s->close;
}

sub connect_p {
  my $self = shift;
  my $connect = shift || {};
  Scalar::Util::weaken($self);
  return Mojo::Promise->new(sub {
    my ($res, $rej) = @_;
    $connect->{address} ||= $self->host;
    $connect->{port}    ||= $self->port;
    Mojo::IOLoop->client($connect, sub {
      my (undef, $err, $stream) = @_;
      return $rej->("Connect error: $err") if $err;

      #TODO configurable timeout
      $stream->timeout(0);
      $self->{stream} = $stream;
      #TODO handle backpressure

      $stream->on(read => sub {
        my (undef, $bytes) = @_;
        print STDERR '<- ' . Mojo::Util::term_escape($bytes) . "\n" if DEBUG;
        $self->{buffer} .= $bytes;
        while($self->{buffer} =~ s/^([^;]+;)//) {
          eval { $self->emit(instruction => $1) };
        }
      });

      $stream->on(error => sub {
        $self->emit(error => $_[1]);
      });

      $stream->on(close => sub {
        print STDERR "Connection to guacd closed\n" if DEBUG;
        return unless $self;
        delete @{$self}{qw(buffer id stream)};
        $self->emit('close');
      });

      $res->();
    });
  });
}

sub handshake_p {
  Scalar::Util::weaken(my $self = shift);

  return Mojo::Promise->reject('Not connected')
    unless my $stream = $self->{stream};

  my $args;
  return $self->_expect(args => [select => $self->protocol])
    ->then(sub {
      my $got = shift;
      my $version = shift @$got;
      #TODO check version
      $args = $got;
      $self->write_p(encode([size => $self->width, $self->height, $self->dpi]));
    })
    ->then(sub{ $self->write_p(encode([audio => @{ $self->audio_mimetypes } ])) })
    ->then(sub{ $self->write_p(encode([image => @{ $self->image_mimetypes } ])) })
    ->then(sub{ $self->write_p(encode([video => @{ $self->video_mimetypes } ])) })
    ->then(sub{
      my @connect = (connect => 'VERSION_1_1_0');
      my $proto = $self->connection_args;
      push @connect,  map { $proto->{$_} // '' } @$args;
      $self->_expect(ready => \@connect);
    })
    ->then(sub {
      my $id = shift;
      print STDERR "Session $id->[0] is ready" if DEBUG;
      $self->{id} = $id->[0];
      return $id->[0];
    })->catch(sub { Mojo::Promise->reject("Handshake error: $_[0]") });
}

sub write {
  my ($self, $bytes) = @_;
  Carp::croak('Not connected')
    unless my $s = $self->{stream};
  print STDERR '-> ' . Mojo::Util::term_escape($bytes) . "\n" if DEBUG;
  $self->{stream}->write($bytes);
}

sub write_p {
  my ($self, $bytes) = @_;
  return Mojo::Promise->reject('Not connected')
    unless my $s = $self->{stream};

  my $p = Mojo::Promise->new;
  print STDERR '-> ' . Mojo::Util::term_escape($bytes) . "\n" if DEBUG;
  $self->{stream}->write($bytes, sub { $p->resolve });
  return $p;
}

sub _expect {
  my ($self, $command, $send) = @_;
  my $p = Mojo::Promise->new;

  $self->once(instruction => sub {
    my (undef, $raw) = @_;
    my $instruction = decode($raw);
    my $got = shift @$instruction;
    if ($got eq $command) {
      $p->resolve($instruction);
    } else {
      $p->reject("Unexpected command $got received, expecting $command");
    }
  });

  $self->write_p(encode($send))
    ->catch(sub { $p->reject("Send failed: $_[0]") });

  return $p;
}

## FUNCTIONS!

sub encode {
  my $words = shift;
  return join(',', map { $_ //= ''; length . '.' . Mojo::Util::encode('UTF-8', $_) } @$words) . ";";
}

sub decode {
  my $line = Mojo::Util::decode('UTF-8', shift);
  Carp::croak 'Instruction does not end with ;'
    unless $line =~ s/;$//;

  my @words =
    map {
      my ($l, $s) = split /\./, $_, 2;
      Carp::croak 'Word length mismatch'
        unless length($s) == $l;
      $s;
    }
    split ',', $line;

  return \@words;
}


1;

