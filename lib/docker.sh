#!/usr/bin/env bash
# Docker setup shared functions for Walph Riggum project

# Create Docker configuration files from templates
# Usage: create_docker_setup <target_dir> <stack> [project_name] [with_postgres]
#   target_dir: Directory to create Docker files in
#   stack: "node", "python", or "both"
#   project_name: Project name (optional, defaults to "app")
#   with_postgres: "true" or "false" (optional, defaults to "true")
create_docker_setup() {
    local target_dir="$1"
    local stack="$2"
    local project_name="${3:-app}"
    local with_postgres="${4:-true}"

    if [[ ! -d "$target_dir" ]]; then
        log_error "Target directory does not exist: $target_dir"
        return 1
    fi

    log_info "Creating Docker configuration..."

    mkdir -p "$target_dir/docker"

    # Determine app port based on stack
    local app_port="3000"
    if [[ "$stack" == "python" ]]; then
        app_port="8000"
    fi

    # Create docker-compose.yml based on template
    local template_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/templates/docker"

    if [[ -f "$template_dir/docker-compose.yml" && "$with_postgres" == "true" ]]; then
        # Use template with variable substitution
        sed -e "s/3000:3000/$app_port:$app_port/g" \
            -e "s/POSTGRES_DB=app/POSTGRES_DB=$project_name/g" \
            -e "s/DATABASE_URL=postgres:\/\/postgres:postgres@db:5432\/app/DATABASE_URL=postgres:\/\/postgres:postgres@db:5432\/$project_name/g" \
            "$template_dir/docker-compose.yml" > "$target_dir/docker-compose.yml"
    elif [[ "$with_postgres" == "false" ]]; then
        # Create simplified compose file without Postgres
        cat > "$target_dir/docker-compose.yml" << EOF
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: docker/Dockerfile
    ports:
      - "$app_port:$app_port"
    volumes:
      - .:/app
      - /app/node_modules
    environment:
      - NODE_ENV=development
    restart: unless-stopped
EOF
    else
        # Fallback to simple inline version if template not found
        cat > "$target_dir/docker-compose.yml" << EOF
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: docker/Dockerfile
    ports:
      - "$app_port:$app_port"
    volumes:
      - .:/app
      - /app/node_modules
    environment:
      - NODE_ENV=development
      - DATABASE_URL=postgres://postgres:postgres@db:5432/$project_name
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  db:
    image: postgres:15-alpine
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=$project_name
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  postgres_data:
EOF
    fi

    # Create Dockerfile based on stack and templates
    case "$stack" in
        python)
            if [[ -f "$template_dir/Dockerfile.python" ]]; then
                # Use template file but create simplified version for init
                cat > "$target_dir/docker/Dockerfile" << 'EOF'
FROM python:3.11-slim

WORKDIR /app

# Prevent Python from writing pyc files
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Install dependencies
COPY requirements*.txt ./
RUN pip install --no-cache-dir -r requirements.txt 2>/dev/null || echo "No requirements.txt yet"

# Copy source
COPY . .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
EOF
            else
                # Fallback inline version
                cat > "$target_dir/docker/Dockerfile" << 'EOF'
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements*.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY . .

EXPOSE 8000

CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF
            fi
            ;;
        node|both|*)
            if [[ -f "$template_dir/Dockerfile.node" ]]; then
                # Use simplified version of node template for init
                cat > "$target_dir/docker/Dockerfile" << 'EOF'
FROM node:20-alpine

WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci 2>/dev/null || npm init -y

# Copy source
COPY . .

EXPOSE 3000

CMD ["npm", "run", "dev"]
EOF
            else
                # Fallback inline version
                cat > "$target_dir/docker/Dockerfile" << 'EOF'
FROM node:20-alpine

WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci

# Copy source
COPY . .

# Build
RUN npm run build || true

EXPOSE 3000

CMD ["npm", "start"]
EOF
            fi
            ;;
    esac

    log_info "Docker configuration created"
}
