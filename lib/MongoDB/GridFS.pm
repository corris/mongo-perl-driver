#
#  Copyright 2009 10gen, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

package MongoDB::GridFS;
our $VERSION = '0.43';

# ABSTRACT: A file storage utility

use Any::Moose;
use MongoDB::GridFS::File;
use DateTime;
use Digest::MD5;

=head1 NAME

MongoDB::GridFS - A file storage utility

=head1 SYNOPSIS

    use MongoDB::GridFS;

    my $grid = $database->get_gridfs;
    my $fh = IO::File->new("myfile", "r");
    $grid->insert($fh, {"filename" => "mydbfile"});

There are two interfaces for GridFS: a file-system/collection-like interface
(insert, remove, drop, find_one) and a more general interface 
(get, put, delete).  Their functionality is the almost identical (get, put and 
delete are always safe ops, insert, remove, and find_one are optionally safe), 
using one over the other is a matter of preference.

=head1 SEE ALSO

Core documentation on GridFS: L<http://dochub.mongodb.org/core/gridfs>.

=head1 ATTRIBUTES

=head2 chunk_size

The number of bytes per chunk.  Defaults to 1048576.

=cut

$MongoDB::GridFS::chunk_size = 1048576;

has _database => (
    is       => 'ro',
    isa      => 'MongoDB::Database',
    required => 1,
);

=head2 prefix

The prefix used for the collections.  Defaults to "fs".

=cut

has prefix => (
    is      => 'ro',
    isa     => 'Str',
    default => 'fs'
);

=head2 files

Collection in which file metadata is stored.  Each document contains md5 and 
length fields, plus user-defined metadata (and an _id). 

=cut

has files => (
    is => 'ro',
    isa => 'MongoDB::Collection',
    lazy_build => 1
);
sub _build_files {
  my $self = shift;
  my $coll = $self->_database->get_collection($self->prefix . '.files');
  # ensure the necessary index is present (this may be first usage)
  $coll->ensure_index(Tie::IxHash->new(filename => 1), {"safe" => 1});
  return $coll;
}

=head2 chunks

Actual content of the files stored.  Each chunk contains up to 4Mb of data, as 
well as a number (its order within the file) and a files_id (the _id of the file 
in the files collection it belongs to).  

=cut

has chunks => (
    is => 'ro',
    isa => 'MongoDB::Collection',
    lazy_build => 1
);
sub _build_chunks {
  my $self = shift;
  my $coll = $self->_database->get_collection($self->prefix . '.chunks');
  # ensure the necessary index is present (this may be first usage)
  $coll->ensure_index(Tie::IxHash->new(files_id => 1, n => 1), {"safe" => 1});
  return $coll;
}

=head1 METHODS

=head2 get($id)

    my $file = $grid->get("my file");

Get a file from GridFS based on its _id.  Returns a L<MongoDB::GridFS::File>.

=cut

sub get {
    my ($self, $id) = @_;

    return $self->find_one({_id => $id});
}

=head2 put($fh, $metadata)

    my $id = $grid->put($fh, {filename => "pic.jpg"});

Inserts a file into GridFS, adding a L<MongoDB::OID> as the _id field if the 
field is not already defined.  This is a wrapper for C<MongoDB::GridFS::insert>,
see that method below for more information.  

Returns the _id field.

=cut

sub put {
    my ($self, $fh, $metadata) = @_;

    return $self->insert($fh, $metadata, {safe => 1});
}

=head2 delete($id)

    $grid->delete($id)

Removes the file with the given _id.  Will die if the remove is unsuccessful.
Does not return anything on success.

=cut

sub delete {
    my ($self, $id) = @_;

    $self->remove({_id => $id}, {safe => 1});
}

=head2 find_one ($criteria?, $fields?)

    my $file = $grid->find_one({"filename" => "foo.txt"});

Returns a matching MongoDB::GridFS::File or undef.

=cut

sub find_one {
    my ($self, $criteria, $fields) = @_;

    my $file = $self->files->find_one($criteria, $fields);
    return undef unless $file;
    return MongoDB::GridFS::File->new({_grid => $self,info => $file});
}

=head2 remove ($criteria?, $options?)

    $grid->remove({"filename" => "foo.txt"});

Cleanly removes files from the database.  C<$options> is a hash of options for
the remove.  Possible options are:

=over 4

=item just_one
If true, only one file matching the criteria will be removed.

=item safe
If true, each remove will be checked for success and die on failure.

=back

This method doesn't return anything.

=cut

sub remove {
    my ($self, $criteria, $options) = @_;

    my $just_one = 0;
    my $safe = 0;

    if (defined $options) {
        if (ref $options eq 'HASH') {
            $just_one = $options->{just_one} && 1;
            $safe = $options->{safe} && 1;
        }
        elsif ($options) {
            $just_one = $options && 1;
        }
    }

    if ($just_one) {
        my $meta = $self->files->find_one($criteria);
        $self->chunks->remove({"files_id" => $meta->{'_id'}}, {safe => $safe});
        $self->files->remove({"_id" => $meta->{'_id'}}, {safe => $safe});
    }
    else {
        my $cursor = $self->files->query($criteria);
        while (my $meta = $cursor->next) {
            $self->chunks->remove({"files_id" => $meta->{'_id'}}, {safe => $safe});
        }
        $self->files->remove($criteria, {safe => $safe});
    }
}


=head2 insert ($fh, $metadata?, $options?)

    my $id = $gridfs->insert($fh, {"content-type" => "text/html"});

Reads from a file handle into the database.  Saves the file with the given 
metadata.  The file handle must be readable.  C<$options> can be 
C<{"safe" => true}>, which will do safe inserts and check the MD5 hash
calculated by the database against an MD5 hash calculated by the local 
filesystem.  If the two hashes do not match, then the chunks already inserted
will be removed and the program will die.

Because C<MongoDB::GridFS::insert> takes a file handle, it can be used to insert
very long strings into the database (as well as files).  C<$fh> must be a 
FileHandle (not just the native file handle type), so you can insert a string 
with:

    # open the string like a file
    my $basic_fh;
    open($basic_fh, '<', \$very_long_string);

    # turn the file handle into a FileHandle
    my $fh = FileHandle->new;
    $fh->fdopen($basic_fh, 'r');

    $gridfs->insert($fh);

=cut

sub insert {
    my ($self, $fh, $metadata, $options) = @_;
    $options ||= {};

    confess "not a file handle" unless $fh;
    $metadata = {} unless $metadata && ref $metadata eq 'HASH';

    $self->chunks->ensure_index(Tie::IxHash->new(files_id => 1, n => 1), 
                                {"safe" => 1});

    my $start_pos = $fh->getpos();

    my $id;
    if (exists $metadata->{"_id"}) {
        $id = $metadata->{"_id"};
    }
    else {
        $id = MongoDB::OID->new;
    }

    my $n = 0;
    my $length = 0;
    while ((my $len = $fh->read(my $data, $MongoDB::GridFS::chunk_size)) != 0) {
        $self->chunks->insert({"files_id" => $id,
                               "n" => $n,
                               "data" => bless(\$data)}, $options);
        $n++;
        $length += $len;
    }
    $fh->setpos($start_pos);

    # get an md5 hash for the file
    my $result = $self->_database->run_command({"filemd5", $id, 
                                                "root" => $self->prefix});

    # compare the md5 hashes
    if ($options->{safe}) {
        my $md5 = Digest::MD5->new;
        $md5->addfile($fh);
        my $digest = $md5->hexdigest;
        if ($digest ne $result->{md5}) {
            # cleanup and die
            $self->chunks->remove({files_id => $id});
            die "md5 hashes don't match: database got $result->{md5}, fs got $digest";
        }
    }

    my %copy = %{$metadata};
    $copy{"_id"} = $id;
    $copy{"md5"} = $result->{"md5"};
    $copy{"chunkSize"} = $MongoDB::GridFS::chunk_size;
    $copy{"uploadDate"} = DateTime->now;
    $copy{"length"} = $length;
    return $self->files->insert(\%copy, $options);
}

=head2 drop

    @files = $grid->drop;

Removes all files' metadata and contents.

=cut

sub drop {
    my ($self) = @_;

    $self->files->drop;
    $self->chunks->drop;
}

=head2 all

    @files = $grid->all;

Returns a list of the files in the database.

=cut

sub all {
    my ($self) = @_;
    my @ret;

    my $cursor = $self->files->query;
    while (my $meta = $cursor->next) {
        push @ret, MongoDB::GridFS::File->new(
            _grid => $self, 
            info => $meta); 
    }
    return @ret;
}

1;

=head1 AUTHOR

  Kristina Chodorow <kristina@mongodb.org>
