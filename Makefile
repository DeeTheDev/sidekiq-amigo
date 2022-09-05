install:
	bundle install
cop:
	bundle exec rubocop
fix:
	bundle exec rubocop --autocorrect-all
fmt: fix

up:
	docker compose up -d
test:
	RACK_ENV=test bundle exec rspec spec/
testf:
	RACK_ENV=test bundle exec rspec spec/ --fail-fast --seed=1

build:
	gem build sidekiq-amigo.gemspec
	# gem push sidekiq-amigo-x.y.z.gem
