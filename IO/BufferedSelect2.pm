package IO::BufferedSelect2;

use strict;
use warnings;
use IO::BufferedSelect;

sub new
{
    my $class   = shift;
    my @handles = @_;

    my $self = { 'bs' => undef};
    
    if(scalar @handles)
    {
        $self->{'bs'} = IO::BufferedSelect->new(@handles);
    }else{
        $self->{'bs'} = IO::BufferedSelect->new();
    }
    return bless $self;
}

sub add
{
    my $self = shift;
    my @hlist = @_;
    my $added = 0;
    return 0 if scalar @hlist < 1;
    my $bs = $self->{'bs'};
    foreach my $fh (@hlist)
    {
        push @{$bs->{'handles'}}, $fh;
        push @{$bs->{'buffers'}}, '';
        push @{$bs->{'eof'}}, 0;
        $bs->{'selector'}->add($fh);
        $added++;
    }
    return $added;
}
sub remove
{
    my $self = shift;
    my @hlist = @_;
    my $deleted = 0;
    
    return 0 if scalar @hlist < 1;
    
    my $bs = $self->{'bs'};
    foreach my $fh (@hlist)
    {
        $bs->{'selector'}->remove($fh);
        my $idx = undef;
        foreach my $i( 0..$#{$bs->{handles}} )
        {
            if($bs->{handles}->[$i] == $fh)
            {
                $idx = $i;
            }
        }
        if(defined $idx)
        {
            splice(@{$bs->{'handles'}}, $idx, 1);
            splice(@{$bs->{'eof'}}, $idx, 1);
            splice(@{$bs->{'buffers'}}, $idx, 1);
            $deleted++;
        }
    }
    return $deleted;
}

sub read_line($;$@)
{
    my $self = shift;
    my ($timeout, @handles) = @_;
    return $self->{'bs'}->read_line($timeout, @handles);
}

1;
