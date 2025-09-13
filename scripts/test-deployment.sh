#!/bin/bash
# Comprehensive deployment safety testing script
set -euo pipefail

DEPLOY_PATH="/opt/n8n-v2"
SHARED="$DEPLOY_PATH/shared"
CURRENT="$DEPLOY_PATH/current"

echo "🧪 Testing deployment safety and integrity..."
echo "================================================"

# Test 1: Verify directory structure
echo "1. 📁 Checking directory structure..."
for path in current releases shared shared/services shared/backups shared/env; do
  full_path="$DEPLOY_PATH/$path"
  if [ -e "$full_path" ]; then
    echo "  ✅ Exists: $path"
  else
    echo "  ❌ Missing: $path"
    exit 1
  fi
done

# Test 2: Verify current symlink points to valid release
echo ""
echo "2. 🔗 Checking current symlink..."
if [ -L "$CURRENT" ]; then
  target=$(readlink -f "$CURRENT")
  if [[ "$target" =~ $DEPLOY_PATH/releases/ ]]; then
    release_name=$(basename "$target")
    echo "  ✅ Current points to valid release: $release_name"

    # Check if release has required symlinks
    if [ -L "$target/services" ] && [ -L "$target/env" ]; then
      echo "  ✅ Release has proper symlinks to shared resources"
    else
      echo "  ⚠️ Release missing symlinks to shared resources"
    fi
  else
    echo "  ❌ Current points outside releases directory: $target"
    exit 1
  fi
else
  echo "  ❌ Current is not a symlink"
  exit 1
fi

# Test 3: Verify services use stable project names
echo ""
echo "3. 🐳 Checking Docker Compose project names..."
stable_projects=0
unstable_projects=0

for container in $(docker ps --format '{{.Names}}'); do
  project=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || echo "")

  if [ -n "$project" ]; then
    echo "  Container: $container → Project: $project"

    # Verify project name matches expected pattern
    case "$container" in
      edge-*)
        if [ "$project" = "edge" ]; then
          ((stable_projects++))
        else
          echo "    ⚠️ Expected project 'edge', got '$project'"
          ((unstable_projects++))
        fi
        ;;
      monitoring-*)
        if [ "$project" = "monitoring" ]; then
          ((stable_projects++))
        else
          echo "    ⚠️ Expected project 'monitoring', got '$project'"
          ((unstable_projects++))
        fi
        ;;
      *-db|*_postgres)
        # Database containers should use their service's project name
        service_name="${container%-*}"
        service_name="${service_name%_*}"
        if [ "$project" = "$service_name" ]; then
          ((stable_projects++))
        else
          echo "    ⚠️ Expected project '$service_name', got '$project'"
          ((unstable_projects++))
        fi
        ;;
      *)
        # Service containers should match their service name
        service_name="${container%%-*}"
        service_name="${service_name%%_*}"
        if [ "$project" = "$service_name" ]; then
          ((stable_projects++))
        else
          echo "    ⚠️ Expected project '$service_name', got '$project'"
          ((unstable_projects++))
        fi
        ;;
    esac
  fi
done

echo "  📊 Project names: $stable_projects stable, $unstable_projects unstable"
if [ $unstable_projects -gt 0 ]; then
  echo "  ⚠️ Some containers have unstable project names"
fi

# Test 4: Verify Docker volumes exist and are named consistently
echo ""
echo "4. 💾 Checking Docker volumes..."
volume_count=0
for vol in $(docker volume ls -q | grep -E 'n8n|ollama|qdrant' | sort); do
  created=$(docker volume inspect "$vol" --format '{{.CreatedAt}}' 2>/dev/null | cut -d'T' -f1)
  size=$(docker run --rm -v "$vol":/data alpine sh -c 'du -sh /data' 2>/dev/null | cut -f1 || echo "unknown")
  echo "  ✅ Volume: $vol (created: $created, size: $size)"
  ((volume_count++))
done

echo "  📊 Total persistent volumes: $volume_count"

# Test 5: Check backup freshness
echo ""
echo "5. 📦 Checking backup freshness..."
backup_dirs=("$SHARED/backups/configs" "$SHARED/backups/databases" "$SHARED/backups/volumes")

for backup_dir in "${backup_dirs[@]}"; do
  if [ -d "$backup_dir" ]; then
    backup_type=$(basename "$backup_dir")
    latest_backup=$(find "$backup_dir" -type f \( -name "*.tar.gz" -o -name "*.dump" -o -name "*.sql" \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)

    if [ -n "$latest_backup" ]; then
      age_hours=$(( ($(date +%s) - $(stat -c %Y "$latest_backup")) / 3600 ))
      backup_name=$(basename "$latest_backup")
      echo "  ✅ Latest $backup_type backup: $backup_name ($age_hours hours old)"

      if [ $age_hours -gt 24 ]; then
        echo "    ⚠️ Backup is older than 24 hours"
      fi
    else
      echo "  ⚠️ No $backup_type backups found"
    fi
  else
    echo "  ⚠️ Backup directory missing: $backup_dir"
  fi
done

# Test 6: Verify file permissions
echo ""
echo "6. 🔒 Checking file permissions..."
insecure_count=0

if [ -d "$SHARED/services" ]; then
  while IFS= read -r -d '' env_file; do
    perms=$(stat -c %a "$env_file")
    if [ "$perms" = "600" ]; then
      echo "  ✅ Secure permissions: $(basename "$(dirname "$env_file")")/.env ($perms)"
    else
      echo "  ❌ Insecure permissions: $env_file ($perms)"
      ((insecure_count++))
    fi
  done < <(find "$SHARED/services" -name ".env" -print0 2>/dev/null)
fi

if [ $insecure_count -gt 0 ]; then
  echo "  ⚠️ Found $insecure_count files with insecure permissions"
fi

# Test 7: Check service configuration integrity
echo ""
echo "7. ⚙️ Checking service configuration integrity..."
if [ -d "$SHARED/services" ]; then
  for service_dir in "$SHARED/services"/*/; do
    if [ -d "$service_dir" ]; then
      service_name=$(basename "$service_dir")
      compose_file="$service_dir/compose.yml"
      env_file="$service_dir/.env"

      if [ -f "$compose_file" ]; then
        echo "  ✅ Service $service_name has compose.yml"

        # Check if compose file is valid
        if cd "$service_dir" && docker compose -p "$service_name" config >/dev/null 2>&1; then
          echo "    ✅ Compose configuration is valid"
        else
          echo "    ❌ Compose configuration is invalid"
        fi
      else
        echo "  ❌ Service $service_name missing compose.yml"
      fi

      if [ -f "$env_file" ]; then
        echo "  ✅ Service $service_name has .env file"
      else
        echo "  ⚠️ Service $service_name missing .env file"
      fi
    fi
  done
fi

# Test 8: Check release history
echo ""
echo "8. 📚 Checking release history..."
if [ -d "$DEPLOY_PATH/releases" ]; then
  release_count=$(find "$DEPLOY_PATH/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
  echo "  📊 Total releases: $release_count"

  echo "  📋 Recent releases:"
  find "$DEPLOY_PATH/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -rn | head -3 | cut -d' ' -f2- | while read -r release; do
    release_path="$DEPLOY_PATH/releases/$release"
    if [ -f "$release_path/RELEASE_ID" ]; then
      echo "    ✅ $release (has metadata)"
    else
      echo "    ⚠️ $release (missing metadata)"
    fi
  done

  if [ "$release_count" -gt 5 ]; then
    echo "  ⚠️ More than 5 releases exist - cleanup may be needed"
  fi
fi

# Test 9: Network connectivity
echo ""
echo "9. 🌐 Checking network connectivity..."
networks=("edge" "ai-internal" "monitoring")
for network in "${networks[@]}"; do
  if docker network inspect "$network" >/dev/null 2>&1; then
    echo "  ✅ Network exists: $network"
  else
    echo "  ❌ Network missing: $network"
  fi
done

# Test 10: Health check summary
echo ""
echo "10. 🏥 Container health summary..."
healthy_count=0
unhealthy_count=0
no_health_count=0

while IFS= read -r line; do
  if [[ "$line" == *"(healthy)"* ]]; then
    ((healthy_count++))
  elif [[ "$line" == *"(unhealthy)"* ]]; then
    echo "  ❌ Unhealthy: $line"
    ((unhealthy_count++))
  else
    ((no_health_count++))
  fi
done < <(docker ps --format "{{.Names}} {{.Status}}")

echo "  📊 Container health: $healthy_count healthy, $unhealthy_count unhealthy, $no_health_count no health check"

if [ $unhealthy_count -gt 0 ]; then
  echo "  ⚠️ Some containers are unhealthy"
fi

# Final summary
echo ""
echo "================================================"
echo "🎯 SAFETY TEST SUMMARY"
echo "================================================"

issues=0
if [ $unstable_projects -gt 0 ]; then ((issues++)); fi
if [ $insecure_count -gt 0 ]; then ((issues++)); fi
if [ $unhealthy_count -gt 0 ]; then ((issues++)); fi

if [ $issues -eq 0 ]; then
  echo "✅ ALL SAFETY CHECKS PASSED"
  echo "   Deployment is stable and secure"
else
  echo "⚠️  ISSUES FOUND: $issues categories need attention"
  echo "   Review the warnings above"
fi

echo ""
echo "📋 Quick stats:"
echo "   - Releases: $release_count"
echo "   - Volumes: $volume_count"
echo "   - Containers: $((healthy_count + unhealthy_count + no_health_count))"
echo "   - Project names: $stable_projects stable, $unstable_projects unstable"

exit $issues