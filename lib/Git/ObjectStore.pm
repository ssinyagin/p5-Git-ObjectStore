use strict;
use warnings;
use Carp;
use File::Spec::Functions qw(catfile);

package Git::ObjectStore;

# ABSTRACT: abstraction layer for Git::Raw and libgit2

=head1 SYNOPSIS

=head1 DESCRIPTION

This module provides an abstraction level on top of L<Git::Raw>, a Perl
wrapper for F<libgit2>, in order to use a bare Git repository as an
object store. The objects are written into a mempack, and then flushed
to disk, so thousands of objects can be created without polluting your
filesystem and exxhausting its inode pool.

=cut

=method new(%args)

Creates a new object. If F<repodir> is empty or does not exist, the
method initializes a new bare Git repository. If multiple processes may
call this method simultaneously, it is up to you to provide locking, so
that the objects are created one at a time.

Mandatory arguments:

=for :list
* C<repodir>: the directory path where the bare Git repository is located.
* C<branchname>: the branch name in the repository. Multiple
    L<Git::ObjectStore> objects can co-exist at the same time in multiple
    or the same process, but the branch names in writer objects need to be
    unique.

Optional arguments:

=for :list
* C<writer>: set to true if this object needs to write new files into the
    repository. Writing is always done at the top of the branch.
* C<goto>: commit identifier where the read operations will be performed.
    This argument cannot be combined with writer mode. By default, reading
    is performed from the top of the branch.
* C<author_name>, C<author_email>: name and email strings used for commits.

=cut


sub new
{
    my ($class, %args) = @_;
    my $self = bless {}, $class;

    $self->{'author_name'} = 'ObjectStore';
    $self->{'author_email'} = 'ObjectStore@localhost';

    foreach my $arg (qw(repodir branchname)) {
        if ( defined( $args{$arg} ) ) {
            $self->{$arg} = $args{$arg};
        } else {
            croak('Mandatory argument missing: ' . $arg);
        }
    }

    foreach my $arg (qw(writer author_name author_email)) {
        if ( defined( $args{$arg} ) ) {
            $self->{$arg} = $args{$arg};
        }
    }

    if ( $self->{'writer'} and $arg{'goto'} ) {
        croak('Cannot use goto in writer mode');
    }

    my $branchname = $self->{'branchname'};
    my $repodir = $self->{'repodir'};

    if ( not -e $repodir . '/config' ) {
        Git::Raw::Repository->init($repodir, 1);
    }

    my $repo = $self->{'repo'} = Git::Raw::Repository->open($repodir);

    if ( $self->{'writer'} ) {

        my $branch = Git::Raw::Branch->lookup($repo, $branchname, 1);

        if ( not defined($branch) ) {
            # This is a fresh repo, create the branch
            my $builder = Git::Raw::Tree::Builder->new($repo);
            my $tree = $builder->write();
            my $me = $self->_signature();
            my $refname = 'refs/heads/' . $branchname;
            my $commit = $repo->commit("Initial empty commit in $branchname",
                                       $me, $me, [], $tree, $refname);
            $self->{'created_init_commit'} = $commit;
            $branch = Git::Raw::Branch->lookup($repo, $branchname, 1);
        }

        croak('expected a branch') unless defined($branch);

        # in-memory store that will write a single pack file for all objects
        $self->{'packdir'} = catfile($repodir, 'objects', 'pack');
        my $mempack = $self->{'mempack'} = Git::Raw::Mempack->new;
        $repo->odb->add_backend($mempack, 99);

        # in-memory index for preparing a commit
        my $index = Git::Raw::Index->new();

        # assign the index to our repo
        $repo->index($index);

        # initiate the index with the top of the branch
        my $commit = $branch->peel('commit');
        $index->read_tree($commit->tree());

        # memorize the index for quick write access
        $self->{'gitindex'} = $index;

        $self->{'current_commit_id'} = $commit->id();

    } else {
        # open the repo for read-only access
        my $commit;
        if ( defined($arg{'goto'}) ) {
            # read from a specified commit
            $commit = Git::Raw::Commit->lookup($repo, $arg{'goto'});
            croak('Cannot lookup commit ' . $arg{'goto'})
                unless defined($commit);
        } else {
            # read from the top of the branch
            my $branch = Git::Raw::Branch->lookup($repo, $branchname, 1);
            $commit = $branch->peel('commit');
        }

        # memorize the tree that we will read
        $self->{'gittree'} = $commit->tree();

        $self->{'current_commit_id'} = $commit->id();
    }

    return $self;
}


sub _signature
{
    my $self = shift;
    return Git::Raw::Signature->now
        ($self->{'author_name'}, $self->{'author_email'});
}


=method read_file($path)

This method reads a file from a given path within the branch. It returns
undef if the file is not found. In writer mode, the file is checked
first in the in-memory mempack. The returned value is the file content
as a scalar.

=cut

sub read_file
{
    my $self = shift;
    my $filename = shift;

    if ( $self->{'writer'} ) {
        my $entry = $self->{'gitindex'}->find($filename);
        if ( defined($entry) ) {
            return $entry->blob()->content();
        } else {
            return undef;
        }
    } else {
        my $entry = $self->{'gittree'}->entry_bypath($filename);
        if ( defined($entry) ) {
            return $entry->object()->content();
        } else {
            return undef;
        }
    }
}


=method file_exists($path)

This method returns true if the given file extsis in the branch.

=cut

sub file_exists
{
    my $self = shift;
    my $filename = shift;

    if ( $self->{'writer'} ) {
        return defined($self->{'gitindex'}->find($filename));
    } else {
        return defined($self->{'gittree'}->entry_bypath($filename));
    }
}

=method current_commit_id()

Returns the current commit identifier. This can be useful for detecting
if there are any changes in the branch and retrieve the difference.

=cut

sub current_commit_id
{
    my $self = shift;
    return $self->{'current_commit_id'};
}


=method write_file($path, $data)

This method writes the data scalar to the repository under specified
file name. It returns true if the data differs from the previous version
or a new file is created. It returns false if the new data is identical
to what has been written before. The data can be a scalar or a reference
to scalar.

=cut

sub write_file
{
    my $self = shift;
    my $filename = shift;
    my $data = shift;

    croak('write_file() is called for a read-only ObjectStore object')
        unless $self->{'writer'};

    my $prev_blob_id = '';
    if( defined(my $entry = $self->{'gitindex'}->find($filename)) ) {
        $prev_blob_id = $entry->blob()->id();
    }

    my $entry = $self->{'gitindex'}->add_frombuffer($filename, $data);
    my $new_blob_id = $entry->blob()->id();

    return ($new_blob_id ne $prev_blob_id);
}


=method write_file_nocheck($path, $data)

This method is similar to C<write_file>, but it does not compare the
content revisions. It is useful for massive write operations where speed
is important.

=cut

sub write_file_nocheck
{
    my $self = shift;
    my $filename = shift;
    my $data = shift;

    croak('write_file() is called for a read-only ObjectStore object')
        unless $self->{'writer'};

    $self->{'gitindex'}->add_frombuffer($filename, $data);
    return;
}


=method create_commit([$msg])

This method checks if any new content is written, and creates a Git
commit if there is a change. The return value is true if a new commit
has been created, or false otherwise. An optional argument can specify
the commit message. If a message is not specified, current localtime is
used instead.

=cut

sub create_commit
{
    my $self = shift;
    my $msg = shift;

    croak('create_commit() is called for a read-only ObjectStore object')
        unless $self->{'writer'};

    if( not defined($msg) ) {
        $msg = scalar(localtime(time()));
    }

    my $branchname = $self->{'branchname'};
    my $repo = $self->{'repo'};
    my $index = $self->{'gitindex'};

    my $branch = Git::Raw::Branch->lookup($self->{'repo'}, $branchname, 1);
    my $parent = $branch->peel('commit');

    # this creates a new tree object from changes in the index
    my $tree = $index->write_tree();

    if( $tree->id() eq $parent->tree()->id() ) {
        # The tree identifier has not changed, hence there are no
        # changes in content
        return 0;
    }

    my $me = $self->_signature();
    my $commit = $repo->commit
        ($msg, $me, $me, [$parent], $tree, $branch->name());

    # re-initialize the index
    $index->clear();
    $index->read_tree($tree);

    $self->{'current_commit_id'} = $commit->id();

    return 1;
}


=method write_packfile()

This method writes the contents of mempack onto the disk. This method
must be called after one or several calls of C<create_commit()>, so that
the changes are written to persistent storage.

=cut

sub write_packfile
{
    my $self = shift;

    croak('write_packfile() is called for a read-only ObjectStore object')
        unless $self->{'writer'};

    my $repo = $self->{'repo'};
    my $tp = Git::Raw::TransferProgress->new();
    my $indexer = Git::Raw::Indexer->new($self->{'packdir'}, $repo->odb());

    $indexer->append($self->{'mempack'}->dump($repo), $tp);
    $indexer->commit($tp);
    $self->{'mempack'}->reset;
    return;
}


=method create_commit_and_packfile([$msg])

This method combines C<create_commit()> and C<write_packfile>. The
packfile is only written if there is a change in the content. The method
returns true if any changes were detected.

=cut

sub create_commit_and_packfile
{
    my $self = shift;
    my $msg = shift;

    if( $self->create_commit($msg) ) {
        $self->write_packfile();
        return 1;
    }

    return 0;
}


=method recursive_read($path, $callback)

This method is only supported in reader mode. It reads the directories
recursively and calls the callback for every file it finds. The callback
arguments are the file name and scalar content.

=cut

sub recursive_read
{
    my $self = shift;
    my $path = shift;
    my $callback = shift;

    croak('recursive_read() is called for a read-write ObjectStore object')
        if $self->{'writer'};

    my $entry = $self->{'gittree'}->entry_bypath($path);
    if( defined($entry) ) {
        $self->_do_recursive_read($entry, $path, $callback);
    }
    return;
}


sub _do_recursive_read
{
    my $self = shift;
    my $entry = shift;  # Git::Raw::Tree::Entry object
    my $path = shift;
    my $callback = shift;

    my $obj = $entry->object();

    if( $obj->is_tree() ) {
        # this is a subtree, we read it recursively
        foreach my $child_entry ($obj->entries()) {
            $self->_do_recursive_read
                ($child_entry, $path . '/' . $child_entry->name(), $callback);
        }
    } else {
        &{$callback}($path, $obj->content());
    }

    return;
}


=method read_updates($old_commit_id, $callback_updated, $callback_deleted)

This method is only supported in reader mode. It compares the current
commit with the old commit, and executes the first callback for all
added or updated files, and the second callback for all deleted
files. The first callback gets the file name and scalar content as
arguments, and the second callback gets only the file name.

=cut

sub read_updates
{
    my $self = shift;
    my $old_commit_id = shift;
    my $cb_updated = shift;
    my $cb_deleted = shift;

    my $old_commit = Git::Raw::Commit->lookup($self->{'repo'}, $old_commit_id);
    croak("Cannot lookup commit $old_commit_id") unless defined($old_commit);
    my $old_tree = $old_commit->tree();

    my $new_tree = $self->{'gittree'};

    my $diff = $old_tree->diff
        (
         {
          'tree' => $new_tree,
          'flags' => {
                      'skip_binary_check' => 1,
                     },
         }
        );

    my @deltas = $diff->deltas();
    foreach my $delta (@deltas) {

        my $path = $delta->new_file()->path();

        if( $delta->status() eq 'deleted') {
            &{$cb_deleted}($path);
        } else {
            my $entry = $new_tree->entry_bypath($path);
            &{$cb_updated}($path, $entry->object()->content());
        }
    }

    return;
}







1;

# Local Variables:
# mode: cperl
# indent-tabs-mode: nil
# cperl-indent-level: 4
# cperl-continued-statement-offset: 4
# cperl-continued-brace-offset: -4
# cperl-brace-offset: 0
# cperl-label-offset: -2
# End:
