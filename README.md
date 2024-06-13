# db-backup

This is built with very specific knowledge of how we're laying out applications

It uses the Ruby backup gem to back up live databases.

The script looks for a file db-backup.rb in each directory under /source/docker and loads it in order to get the information needed to back up its database.
