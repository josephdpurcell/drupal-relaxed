#!/bin/sh

set -ev

# Enable dependencies.
mv ~/www/core/modules/system/tests/modules/entity_test ~/www/modules/entity_test
mv ~/www/modules/relaxed/tests/modules/relaxed_test ~/www/modules/relaxed_test
mv ~/www/modules/relaxed/tests/php-client $TRAVIS_BUILD_DIR/
php ~/drush.phar -l http://drupal.loc en --yes entity_test, relaxed_test || true
php ~/drush.phar -l http://drupal2.loc en --yes entity_test, relaxed_test || true

# Create a new role, add 'perform content replication' permission to this role
# and create a user with this role.
php ~/drush.phar -l http://drupal.loc role-create 'Replicator'
php ~/drush.phar -l http://drupal.loc role-add-perm 'Replicator' 'perform content replication'
php ~/drush.phar -l http://drupal.loc user-create replicator --mail="replicator@example.com" --password="replicator"
php ~/drush.phar -l http://drupal.loc user-add-role 'Replicator' replicator

php ~/drush.phar -l http://drupal2.loc role-create 'Replicator'
php ~/drush.phar -l http://drupal2.loc role-add-perm 'Replicator' 'perform content replication'
php ~/drush.phar -l http://drupal2.loc user-create replicator --mail="replicator@example.com" --password="replicator"
php ~/drush.phar -l http://drupal2.loc user-add-role 'Replicator' replicator

cd $TRAVIS_BUILD_DIR/php-client
composer install

# Create a source and target CouchDB database and do the replication.
curl -X PUT localhost:5984/source
curl -X PUT localhost:5984/target

# Load documents from documents.txt and save them in the 'source' database.
while read document
do
  curl -X POST \
       -H "Content-Type: application/json" \
       -d "$document" \
       localhost:5984/source;
done < $TRAVIS_BUILD_DIR/tests/fixtures/documents.txt

# Get all docs from source for debugging.
curl -X GET http://localhost:5984/source/_all_docs

# Run the replication from CouchDB to Drupal.loc.
php $TRAVIS_BUILD_DIR/php-client/replicate.php '{"source": {"dbname": "source"}, "target": {"host": "drupal.loc", "path": "relaxed", "port": 80, "user": "replicator", "password": "replicator", "dbname": "default", "timeout": 10}}';
sleep 60

# Get all docs from drupal.loc for debugging.
curl -X GET http://admin:admin@drupal.loc/relaxed/default/_all_docs

# Run the replication from Drupal.loc to Drupal2.loc.
php $TRAVIS_BUILD_DIR/php-client/replicate.php '{"source": {"host": "drupal.loc", "path": "relaxed", "port": 80, "user": "replicator", "password": "replicator", "dbname": "default", "timeout": 10}, "target": {"host": "drupal2.loc", "path": "relaxed", "port": 80, "user": "replicator", "password": "replicator", "dbname": "default", "timeout": 10}}';
sleep 60

# Get all docs from drupal.loc for debugging.
curl -X GET http://admin:admin@drupal2.loc/relaxed/default/_all_docs

# Run the replication from Drupal2.loc to CouchDB.
php $TRAVIS_BUILD_DIR/php-client/replicate.php '{"source": {"host": "drupal2.loc", "path": "relaxed", "port": 80, "user": "replicator", "password": "replicator", "dbname": "default", "timeout": 10}, "target": {"dbname": "target"}}';
sleep 60

# Get all docs from target to check replication worked.
curl -X GET http://localhost:5984/target/_all_docs | tee /tmp/all_docs.txt

COUNT=$(wc -l < $TRAVIS_BUILD_DIR/tests/fixtures/documents.txt)
USERS=6
COUNT=$(($COUNT + $USERS));
test 1 -eq $(egrep -c "(\"total_rows\"\:$COUNT)" /tmp/all_docs.txt)
