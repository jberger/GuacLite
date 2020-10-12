package GuacLite::Client::Guacd;

use Mojo::Base 'Mojo::EventEmitter', -signatures;

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

sub close ($self) {
  return unless my $s = $self->{stream};
  $s->close;
}

sub connect_p ($self, $connect = {}) {
  Scalar::Util::weaken($self);
  return Mojo::Promise->new(sub ($res, $rej) {
    $connect->{address} ||= $self->host;
    $connect->{port}    ||= $self->port;
    Mojo::IOLoop->client($connect, sub ($, $err, $stream) {
      return $rej->("Connect error: $err") if $err;

      #TODO configurable timeout
      $stream->timeout(0);
      $self->{stream} = $stream;
      #TODO handle backpressure

      $stream->on(read => sub ($, $bytes) {
        print STDERR '<- ' . Mojo::Util::term_escape($bytes) . "\n" if DEBUG;
        $self->{buffer} .= $bytes;
        while($self->{buffer} =~ s/^([^;]+;)//) {
          eval { $self->emit(instruction => $1) };
        }
      });

      $stream->on(error => sub ($, $err) {
        $self->emit(error => $err);
      });

      $stream->on(close => sub ($) {
        print STDERR "Connection to guacd closed\n" if DEBUG;
        return unless $self;
        delete @{$self}{qw(buffer id stream)};
        $self->emit('close');
      });

      $res->();
    });
  });
}

sub handshake_p ($self) {
  Scalar::Util::weaken($self);

  return Mojo::Promise->reject('Not connected')
    unless my $stream = $self->{stream};

  my $args;
  return $self->_expect(args => [select => $self->protocol])
    ->then(sub($got){
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
    ->then(sub($id) {
      print STDERR "Session $id->[0] is ready" if DEBUG;
      $self->{id} = $id->[0];
      return $id->[0];
    })->catch(sub ($err) { Mojo::Promise->reject("Handshake error: $err") });
}

sub write ($self, $bytes) {
  Carp::croak('Not connected')
    unless my $s = $self->{stream};
  print STDERR '-> ' . Mojo::Util::term_escape($bytes) . "\n" if DEBUG;
  $self->{stream}->write($bytes);
}

sub write_p ($self, $bytes) {
  return Mojo::Promise->reject('Not connected')
    unless my $s = $self->{stream};

  my $p = Mojo::Promise->new;
  print STDERR '-> ' . Mojo::Util::term_escape($bytes) . "\n" if DEBUG;
  $self->{stream}->write($bytes, sub { $p->resolve });
  return $p;
}

sub _expect($self, $command, $send) {
  my $p = Mojo::Promise->new;

  $self->once(instruction => sub ($, $raw) {
    my $instruction = decode($raw);
    my $got = shift @$instruction;
    if ($got eq $command) {
      $p->resolve($instruction);
    } else {
      $p->reject("Unexpected command $got received, expecting $command");
    }
  });

  $self->write_p(encode($send))
    ->catch(sub($err) { $p->reject("Send failed: $err") });

  return $p;
}

## FUNCTIONS!

sub encode ($words) {
  return join(',', map { $_ //= ''; length . '.' . Mojo::Util::encode('UTF-8', $_) } @$words) . ";";
}

sub decode ($line) {
  $line = Mojo::Util::decode('UTF-8', $line);
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

