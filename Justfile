# List available recipes.
default:
    @just --list

# Compile all Erlang applications.
compile:
    rebar3 compile

# Build the production Docker image.
docker-build:
    docker build --tag es-xp:local .

# Start the Docker Compose project.
docker-up:
    docker compose up --build

# Run all EUnit tests.
test:
    rebar3 eunit

# Format Erlang sources.
fmt:
    rebar3 fmt

# Check Erlang formatting.
fmt-check:
    rebar3 fmt --check

# Run Erlang linting.
lint:
    rebar3 lint

# Run Dialyzer type analysis.
dialyzer:
    rebar3 dialyzer

# Generate project documentation.
docs:
    rebar3 ex_doc

# Run local Erlang verification.
check: lint dialyzer fmt-check test
