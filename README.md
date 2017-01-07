Git::ObjectStore
================

This module provides an abstraction level on top of Git::Raw, a Perl
wrapper for `libgit2`, in order to use a bare Git repository as an
object store. The objects are written into a mempack, and then flushed
to disk, so thousands of objects can be created without polluting your
filesystem and exhausting its inode pool.

Github homepage:
https://github.com/ssinyagin/p5-Git-ObjectStore

This software is copyright (c) 2017 by Stanislav Sinyagin.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
