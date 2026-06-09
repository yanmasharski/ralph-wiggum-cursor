#!/bin/bash
# Ralph Wiggum: Task Parser with YAML Backend
#
# Parses RALPH_TASK.md and extracts tasks, with optional YAML caching.
# Uses line numbers as task IDs for stable references.
#
# Usage:
#   source task-parser.sh
#   parse_tasks "$workspace"
#   get_next_task "$workspace"
#   mark_task_complete "$workspace" "$task_id"
#
# Cache files:
#   .ralph/tasks.yaml     - Parsed task data (YAML format)
#   .ralph/tasks.mtime    - Mtime of RALPH_TASK.md when cached

# =============================================================================
# CONFIGURATION
# =============================================================================

# Cache directory suffix
TASK_CACHE_FILE="tasks.yaml"
TASK_MTIME_FILE="tasks.mtime"

# Default group for unannotated tasks (999999 = runs last in parallel mode)
# Override with DEFAULT_GROUP=0 to make unannotated tasks run first
DEFAULT_GROUP="${DEFAULT_GROUP:-999999}"

# =============================================================================
# INTERNAL: CACHE MANAGEMENT
# =============================================================================

# Get modification time of a file (cross-platform)
_get_file_mtime() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "0"
    return
  fi
  
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f '%m' "$file" 2>/dev/null || echo "0"
  else
    stat -c '%Y' "$file" 2>/dev/null || echo "0"
  fi
}

# Check if cache is valid (mtime matches)
_is_cache_valid() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  local ralph_dir="$workspace/.ralph"
  local cache_file="$ralph_dir/$TASK_CACHE_FILE"
  local mtime_file="$ralph_dir/$TASK_MTIME_FILE"
  
  # No cache files = invalid
  [[ ! -f "$cache_file" ]] && return 1
  [[ ! -f "$mtime_file" ]] && return 1
  
  # Compare mtimes
  local current_mtime=$(_get_file_mtime "$task_file")
  local cached_mtime
  cached_mtime=$(cat "$mtime_file" 2>/dev/null) || cached_mtime="0"
  
  [[ "$current_mtime" == "$cached_mtime" ]]
}

# Normalize line endings (CRLF -> LF)
_normalize_line_endings() {
  tr -d '\r'
}

# =============================================================================
# INTERNAL: YAML HELPERS
# =============================================================================

# Escape a string for YAML (basic escaping)
_yaml_escape() {
  local str="$1"
  # Replace backslashes first, then quotes
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  # Wrap in quotes if contains special chars
  if [[ "$str" =~ [:\[\]\{\}\,\#\&\*\!\|\>\'\"\%\@\`] ]] || [[ "$str" =~ ^[[:space:]] ]] || [[ "$str" =~ [[:space:]]$ ]]; then
    echo "\"$str\""
  else
    echo "$str"
  fi
}

# Write task cache to YAML format
_write_cache() {
  local workspace="${1:-.}"
  local ralph_dir="$workspace/.ralph"
  local task_file="$workspace/RALPH_TASK.md"
  local cache_file="$ralph_dir/$TASK_CACHE_FILE"
  local mtime_file="$ralph_dir/$TASK_MTIME_FILE"
  
  mkdir -p "$ralph_dir"
  
  # Get current mtime
  local current_mtime=$(_get_file_mtime "$task_file")
  
  # Parse tasks and write YAML
  {
    echo "# Ralph Task Cache"
    echo "# Auto-generated from RALPH_TASK.md"
    echo "# DO NOT EDIT - regenerated on task file change"
    echo ""
    echo "source_file: RALPH_TASK.md"
    echo "source_mtime: $current_mtime"
    echo "generated_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    echo "tasks:"
    
    # Parse task file, extract checkbox items with line numbers
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_num=$((line_num + 1))
      line=$(_normalize_line_endings <<< "$line")
      
      # Match checkbox list items: "- [ ]", "* [x]", "1. [ ]", etc.
      if [[ "$line" =~ ^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x|X|\ )\][[:space:]]+(.*) ]]; then
        local marker="${BASH_REMATCH[1]}"
        local status_char="${BASH_REMATCH[2]}"
        local description="${BASH_REMATCH[3]}"
        
        # Extract parallel_group from line (first match wins)
        # Format: <!-- group: N --> where N is a number
        local parallel_group="$DEFAULT_GROUP"
        if [[ "$line" =~ \<!--[[:space:]]*group:[[:space:]]*([0-9]+)[[:space:]]*--\> ]]; then
          parallel_group="${BASH_REMATCH[1]}"
        fi

        # Extract role from line (optional)
        # Format: <!-- role: name -->
        local role=""
        if [[ "$line" =~ \<!--[[:space:]]*role:[[:space:]]*([a-zA-Z0-9._-]+)[[:space:]]*--\> ]]; then
          role="${BASH_REMATCH[1]}"
        fi
        
        # Strip annotation comments from description for cleanliness
        description="$(sed -E 's/[[:space:]]*<!--[[:space:]]*group:[[:space:]]*[0-9]+[[:space:]]*-->[[:space:]]*//g' <<<"$description")"
        description="$(sed -E 's/[[:space:]]*<!--[[:space:]]*role:[[:space:]]*[a-zA-Z0-9._-]+[[:space:]]*-->[[:space:]]*//g' <<<"$description")"
        
        # Determine status
        local status="pending"
        if [[ "$status_char" == "x" ]] || [[ "$status_char" == "X" ]]; then
          status="completed"
        fi
        
        # Calculate indentation level (each 2 spaces = 1 level)
        local indent="${line%%[![:space:]]*}"
        local indent_level=$(( ${#indent} / 2 ))
        
        # Write YAML entry
        echo "  - id: \"line_$line_num\""
        echo "    line_number: $line_num"
        echo "    status: $status"
        echo "    parallel_group: $parallel_group"
        if [[ -n "$role" ]]; then
          echo "    role: $role"
        fi
        echo "    description: $(_yaml_escape "$description")"
        echo "    indent_level: $indent_level"
        echo "    raw_marker: $(_yaml_escape "$marker")"
      fi
    done < "$task_file"
    
  } > "$cache_file"
  
  # Save mtime
  echo "$current_mtime" > "$mtime_file"
}

# Read a value from YAML cache (simple key extraction)
# Usage: _read_yaml_value "tasks[0].status" < cache.yaml
_read_yaml_simple() {
  local key="$1"
  local file="$2"
  grep "^${key}:" "$file" 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | sed 's/^"//' | sed 's/"$//'
}

# =============================================================================
# PUBLIC: TASK PARSING
# =============================================================================

# Parse tasks from RALPH_TASK.md, update cache if needed
# Returns: 0 on success, 1 on failure
parse_tasks() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Check task file exists
  if [[ ! -f "$task_file" ]]; then
    echo "ERROR: No RALPH_TASK.md found in $workspace" >&2
    return 1
  fi
  
  # Check if cache is still valid
  if _is_cache_valid "$workspace"; then
    return 0
  fi
  
  # Regenerate cache
  _write_cache "$workspace"
  return 0
}

# =============================================================================
# PUBLIC: TASK QUERIES
# =============================================================================

# Get all tasks as line-by-line output
# Format: id|status|description
get_all_tasks() {
  local workspace="${1:-.}"
  local ralph_dir="$workspace/.ralph"
  local cache_file="$ralph_dir/$TASK_CACHE_FILE"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Ensure cache is valid
  parse_tasks "$workspace" || return 1
  
  # If cache exists, use it; otherwise parse directly
  if [[ -f "$cache_file" ]]; then
    # Parse YAML cache (simple line-by-line extraction)
    local current_id="" current_status="" current_desc=""
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
      
      if [[ "$line" =~ ^-\ id:\ \"?([^\"]+)\"?$ ]]; then
        # New task entry - output previous if exists
        if [[ -n "$current_id" ]]; then
          echo "$current_id|$current_status|$current_desc"
        fi
        current_id="${BASH_REMATCH[1]}"
        current_status=""
        current_desc=""
      elif [[ "$line" =~ ^status:\ (.+)$ ]]; then
        current_status="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^description:\ \"?(.*)\"?$ ]]; then
        current_desc="${BASH_REMATCH[1]}"
        # Remove trailing quote if present
        current_desc="${current_desc%\"}"
      fi
    done < "$cache_file"
    
    # Output last task
    if [[ -n "$current_id" ]]; then
      echo "$current_id|$current_status|$current_desc"
    fi
  else
    # Fallback: parse directly from markdown
    _parse_tasks_direct "$task_file"
  fi
}

# Parse tasks directly from markdown (fallback)
_parse_tasks_direct() {
  local task_file="$1"
  local line_num=0
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    line=$(_normalize_line_endings <<< "$line")
    
    if [[ "$line" =~ ^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x|X|\ )\][[:space:]]+(.*) ]]; then
      local status_char="${BASH_REMATCH[2]}"
      local description="${BASH_REMATCH[3]}"
      
      local status="pending"
      if [[ "$status_char" == "x" ]] || [[ "$status_char" == "X" ]]; then
        status="completed"
      fi
      
      echo "line_$line_num|$status|$description"
    fi
  done < "$task_file"
}

# Get all tasks WITH group info (extended format for parallel mode)
# Format: id|status|group|description
# Note: get_all_tasks() is kept stable for backward compatibility
get_all_tasks_with_group() {
  local workspace="${1:-.}"
  local ralph_dir="$workspace/.ralph"
  local cache_file="$ralph_dir/$TASK_CACHE_FILE"
  
  # Ensure cache is valid
  parse_tasks "$workspace" || return 1
  
  if [[ -f "$cache_file" ]]; then
    local current_id="" current_status="" current_group="" current_role="" current_desc=""
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
      
      if [[ "$line" =~ ^-\ id:\ \"?([^\"]+)\"?$ ]]; then
        # New task entry - output previous if exists
        if [[ -n "$current_id" ]]; then
          echo "$current_id|$current_status|$current_group|$current_role|$current_desc"
        fi
        current_id="${BASH_REMATCH[1]}"
        current_status=""
        current_group="$DEFAULT_GROUP"
        current_role=""
        current_desc=""
      elif [[ "$line" =~ ^status:\ (.+)$ ]]; then
        current_status="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^parallel_group:\ (.+)$ ]]; then
        current_group="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^role:\ (.+)$ ]]; then
        current_role="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^description:\ \"?(.*)\"?$ ]]; then
        current_desc="${BASH_REMATCH[1]}"
        current_desc="${current_desc%\"}"
      fi
    done < "$cache_file"
    
    # Output last task
    if [[ -n "$current_id" ]]; then
      echo "$current_id|$current_status|$current_group|$current_role|$current_desc"
    fi
  else
    # Fallback: parse directly (returns default group for all)
    _parse_tasks_direct_with_group "$workspace/RALPH_TASK.md"
  fi
}

# Parse tasks with group directly from markdown (fallback)
_parse_tasks_direct_with_group() {
  local task_file="$1"
  local line_num=0
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    line=$(_normalize_line_endings <<< "$line")
    
    if [[ "$line" =~ ^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x|X|\ )\][[:space:]]+(.*) ]]; then
      local status_char="${BASH_REMATCH[2]}"
      local description="${BASH_REMATCH[3]}"
      
      # Extract group
      local group="$DEFAULT_GROUP"
      if [[ "$line" =~ \<!--[[:space:]]*group:[[:space:]]*([0-9]+)[[:space:]]*--\> ]]; then
        group="${BASH_REMATCH[1]}"
      fi

      local role=""
      if [[ "$line" =~ \<!--[[:space:]]*role:[[:space:]]*([a-zA-Z0-9._-]+)[[:space:]]*--\> ]]; then
        role="${BASH_REMATCH[1]}"
      fi
      
      # Strip annotation comments from description
      description="$(sed -E 's/[[:space:]]*<!--[[:space:]]*group:[[:space:]]*[0-9]+[[:space:]]*-->[[:space:]]*//g' <<<"$description")"
      description="$(sed -E 's/[[:space:]]*<!--[[:space:]]*role:[[:space:]]*[a-zA-Z0-9._-]+[[:space:]]*-->[[:space:]]*//g' <<<"$description")"
      
      local status="pending"
      if [[ "$status_char" == "x" ]] || [[ "$status_char" == "X" ]]; then
        status="completed"
      fi
      
      echo "line_$line_num|$status|$group|$role|$description"
    fi
  done < "$task_file"
}

# Get all pending tasks for a specific group
# Format: id|task_status|group|role|description
get_tasks_by_group() {
  local workspace="${1:-.}"
  local target_group="$2"
  
  get_all_tasks_with_group "$workspace" | while IFS='|' read -r task_id task_status task_group task_role task_desc; do
    if [[ "$task_status" == "pending" ]] && [[ "$task_group" == "$target_group" ]]; then
      echo "$task_id|$task_status|$task_group|$task_role|$task_desc"
    fi
  done
}

# Get sorted list of unique groups that have pending tasks
# Returns one group number per line, sorted numerically
get_pending_groups() {
  local workspace="${1:-.}"
  
  get_all_tasks_with_group "$workspace" | while IFS='|' read -r task_id task_status task_group _task_role _task_desc; do
    if [[ "$task_status" == "pending" ]]; then
      echo "$task_group"
    fi
  done | sort -n | uniq
}

# Get the next incomplete task
# Returns: id|status|description or empty if all complete
get_next_task() {
  local workspace="${1:-.}"
  
  get_all_tasks "$workspace" | while IFS='|' read -r id status desc; do
    if [[ "$status" == "pending" ]]; then
      echo "$id|$status|$desc"
      break
    fi
  done
}

# Get task by ID
# Returns: id|status|description or empty if not found
get_task_by_id() {
  local workspace="${1:-.}"
  local target_id="$2"
  
  get_all_tasks "$workspace" | while IFS='|' read -r id status desc; do
    if [[ "$id" == "$target_id" ]]; then
      echo "$id|$status|$desc"
      break
    fi
  done
}

# Count remaining (pending) tasks
count_remaining() {
  local workspace="${1:-.}"
  local count=0
  
  while IFS='|' read -r id status desc; do
    if [[ "$status" == "pending" ]]; then
      count=$((count + 1))
    fi
  done < <(get_all_tasks "$workspace")
  
  echo "$count"
}

# Count completed tasks
count_completed() {
  local workspace="${1:-.}"
  local count=0
  
  while IFS='|' read -r id status desc; do
    if [[ "$status" == "completed" ]]; then
      count=$((count + 1))
    fi
  done < <(get_all_tasks "$workspace")
  
  echo "$count"
}

# Count total tasks
count_total() {
  local workspace="${1:-.}"
  get_all_tasks "$workspace" | wc -l | tr -d ' '
}

# =============================================================================
# PUBLIC: TASK MODIFICATION
# =============================================================================

# Mark a task as complete by ID (line_N format)
# Modifies RALPH_TASK.md directly
mark_task_complete() {
  local workspace="${1:-.}"
  local task_id="$2"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Extract line number from ID
  if [[ ! "$task_id" =~ ^line_([0-9]+)$ ]]; then
    echo "ERROR: Invalid task ID format: $task_id (expected line_N)" >&2
    return 1
  fi
  local line_num="${BASH_REMATCH[1]}"
  
  # Read the file
  if [[ ! -f "$task_file" ]]; then
    echo "ERROR: Task file not found: $task_file" >&2
    return 1
  fi
  
  # Use sed to replace [ ] with [x] on the specific line
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "${line_num}s/\[ \]/[x]/" "$task_file"
  else
    sed -i "${line_num}s/\[ \]/[x]/" "$task_file"
  fi
  
  # Invalidate cache by removing mtime file
  rm -f "$workspace/.ralph/$TASK_MTIME_FILE"
  
  return 0
}

# Mark a task as incomplete by ID
mark_task_incomplete() {
  local workspace="${1:-.}"
  local task_id="$2"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Extract line number from ID
  if [[ ! "$task_id" =~ ^line_([0-9]+)$ ]]; then
    echo "ERROR: Invalid task ID format: $task_id (expected line_N)" >&2
    return 1
  fi
  local line_num="${BASH_REMATCH[1]}"
  
  if [[ ! -f "$task_file" ]]; then
    echo "ERROR: Task file not found: $task_file" >&2
    return 1
  fi
  
  # Use sed to replace [x] or [X] with [ ] on the specific line
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "${line_num}s/\[[xX]\]/[ ]/" "$task_file"
  else
    sed -i "${line_num}s/\[[xX]\]/[ ]/" "$task_file"
  fi
  
  # Invalidate cache
  rm -f "$workspace/.ralph/$TASK_MTIME_FILE"
  
  return 0
}

# =============================================================================
# PUBLIC: PLAN IMPORT & ROLES
# =============================================================================

# Roles directory override (set via --roles-dir or RALPH_ROLES_DIR)
RALPH_ROLES_DIR="${RALPH_ROLES_DIR:-}"

# Resolve absolute path relative to workspace
_resolve_path() {
  local workspace="$1"
  local path="$2"
  if [[ "$path" = /* ]]; then
    echo "$path"
  else
    echo "$workspace/$path"
  fi
}

# Extract checkbox list lines from a markdown file
_extract_checkbox_lines() {
  local file="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(_normalize_line_endings <<< "$line")
    if [[ "$line" =~ ^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x|X|\ )\][[:space:]]+ ]]; then
      echo "$line"
    fi
  done < "$file"
}

_is_checkbox_line() {
  local line="$1"
  line=$(_normalize_line_endings <<< "$line")
  [[ "$line" =~ ^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x|X|\ )\][[:space:]]+ ]]
}

# Create RALPH_TASK.md from a plan file
_create_ralph_task_from_plan() {
  local workspace="$1"
  local plan_file="$2"
  local checkboxes="$3"
  local task_file="$workspace/RALPH_TASK.md"
  local plan_name
  plan_name=$(basename "$plan_file")

  cat > "$task_file" <<EOF
---
task: Imported from $plan_name
---

# Task

Imported from plan file \`$plan_name\`. Edit this header or add context as needed.

## Success Criteria

$checkboxes
EOF
}

# Replace checkbox items in RALPH_TASK.md with lines from plan file
_merge_plan_checkboxes_into_task() {
  local task_file="$1"
  local plan_checkboxes="$2"
  local tmp
  tmp=$(mktemp)

  local target_section=""
  if grep -q '^## Success Criteria' "$task_file" 2>/dev/null; then
    target_section="## Success Criteria"
  elif grep -q '^## Tasks' "$task_file" 2>/dev/null; then
    target_section="## Tasks"
  elif grep -q '^# Tasks' "$task_file" 2>/dev/null; then
    target_section="# Tasks"
  fi

  local in_target=false
  local inserted=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$target_section" ]] && [[ "$line" == "$target_section" ]]; then
      echo "$line" >> "$tmp"
      in_target=true
      continue
    fi

    if [[ "$in_target" == "true" ]]; then
      if [[ "$line" =~ ^#{1,2}[[:space:]] ]] && [[ "$line" != "$target_section" ]]; then
        if [[ "$inserted" == "false" ]]; then
          echo "" >> "$tmp"
          printf '%s\n' "$plan_checkboxes" >> "$tmp"
          inserted=true
        fi
        in_target=false
        echo "$line" >> "$tmp"
        continue
      fi
      if _is_checkbox_line "$line"; then
        if [[ "$inserted" == "false" ]]; then
          echo "" >> "$tmp"
          printf '%s\n' "$plan_checkboxes" >> "$tmp"
          inserted=true
        fi
        continue
      fi
    elif [[ -z "$target_section" ]] && _is_checkbox_line "$line"; then
      continue
    fi

    echo "$line" >> "$tmp"
  done < "$task_file"

  if [[ "$inserted" == "false" ]]; then
    echo "" >> "$tmp"
    if [[ -z "$target_section" ]]; then
      echo "## Success Criteria" >> "$tmp"
      echo "" >> "$tmp"
    fi
    printf '%s\n' "$plan_checkboxes" >> "$tmp"
  fi

  mv "$tmp" "$task_file"
}

# Import checkbox criteria from a plan markdown file into RALPH_TASK.md
# Usage: import_plan_to_ralph_task "$workspace" "$plan_file"
import_plan_to_ralph_task() {
  local workspace="${1:-.}"
  local plan_file="$2"
  local task_file="$workspace/RALPH_TASK.md"

  plan_file=$(_resolve_path "$workspace" "$plan_file")

  if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan file not found: $plan_file" >&2
    return 1
  fi

  local plan_checkboxes
  plan_checkboxes=$(_extract_checkbox_lines "$plan_file")
  if [[ -z "$plan_checkboxes" ]]; then
    echo "ERROR: No checkbox items found in plan file: $plan_file" >&2
    return 1
  fi

  mkdir -p "$workspace/.ralph"
  echo "$plan_file" > "$workspace/.ralph/plan.source"

  if [[ ! -f "$task_file" ]]; then
    _create_ralph_task_from_plan "$workspace" "$plan_file" "$plan_checkboxes"
  else
    _merge_plan_checkboxes_into_task "$task_file" "$plan_checkboxes"
  fi

  rm -f "$workspace/.ralph/$TASK_MTIME_FILE"
  parse_tasks "$workspace" >/dev/null
  return 0
}

# Find role description file for a role name
# Search order: RALPH_ROLES_DIR, .ralph/roles/, roles/
resolve_role_file() {
  local workspace="${1:-.}"
  local role="$2"
  local candidate=""

  local -a search_dirs=()
  if [[ -n "$RALPH_ROLES_DIR" ]]; then
    search_dirs+=("$(_resolve_path "$workspace" "$RALPH_ROLES_DIR")")
  fi
  search_dirs+=("$workspace/.ralph/roles" "$workspace/roles")

  local dir
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for candidate in "$dir/$role.md" "$dir/${role}/ROLE.md" "$dir/${role}.ROLE.md"; do
      if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done
  done

  return 1
}

# Get role assigned to a task ID (empty if none)
get_task_role() {
  local workspace="${1:-.}"
  local target_id="$2"

  parse_tasks "$workspace" || return 1

  get_all_tasks_with_group "$workspace" | while IFS='|' read -r id _status _group role _desc; do
    if [[ "$id" == "$target_id" ]]; then
      echo "$role"
      break
    fi
  done
}

# Relative path from workspace (for agent prompts)
_role_path_for_prompt() {
  local workspace="$1"
  local role_file="$2"
  if [[ "$role_file" == "$workspace/"* ]]; then
    echo "${role_file#"$workspace/"}"
  else
    echo "$role_file"
  fi
}

# Build markdown list of pending tasks with roles (for agent prompts)
build_role_context() {
  local workspace="${1:-.}"
  local lines=""
  local role role_file rel_path

  parse_tasks "$workspace" || return 0

  while IFS='|' read -r _id status _group role desc; do
    [[ "$status" == "pending" ]] || continue
    [[ -n "$role" ]] || continue

    if role_file=$(resolve_role_file "$workspace" "$role"); then
      rel_path=$(_role_path_for_prompt "$workspace" "$role_file")
      lines+="- **${role}** (${desc}): read \\\`${rel_path}\\\` before starting this criterion"$'\n'
    else
      lines+="- **${role}** (${desc}): read role file before starting — search \\\`.ralph/roles/${role}.md\\\`, \\\`roles/${role}.md\\\`"$'\n'
    fi
  done < <(get_all_tasks_with_group "$workspace")

  if [[ -n "$lines" ]]; then
    cat <<EOF

## Task Roles

Some criteria assign a role. Before working on a criterion with a role, read its role file for perspective, constraints, and conventions:

$lines
EOF
  fi
}

# Copy role directories into a worktree (parallel mode)
copy_role_files_to_worktree() {
  local workspace="$1"
  local worktree_dir="$2"

  if [[ -n "$RALPH_ROLES_DIR" ]]; then
    local roles_path
    roles_path=$(_resolve_path "$workspace" "$RALPH_ROLES_DIR")
    if [[ -d "$roles_path" ]]; then
      mkdir -p "$worktree_dir/.ralph/roles"
      cp -R "$roles_path/." "$worktree_dir/.ralph/roles/" 2>/dev/null || true
    fi
  fi

  if [[ -d "$workspace/.ralph/roles" ]]; then
    mkdir -p "$worktree_dir/.ralph/roles"
    cp -R "$workspace/.ralph/roles/." "$worktree_dir/.ralph/roles/" 2>/dev/null || true
  fi

  if [[ -d "$workspace/roles" ]]; then
    mkdir -p "$worktree_dir/roles"
    cp -R "$workspace/roles/." "$worktree_dir/roles/" 2>/dev/null || true
  fi
}

# Build role instructions for a single task (parallel agents)
build_single_task_role_context() {
  local workspace="$1"
  local task_id="$2"
  local role role_file rel_path desc

  role=$(get_task_role "$workspace" "$task_id")
  [[ -n "$role" ]] || return 0

  while IFS='|' read -r id _status _group task_role task_desc; do
    if [[ "$id" == "$task_id" ]]; then
      desc="$task_desc"
      break
    fi
  done < <(get_all_tasks_with_group "$workspace")

  if role_file=$(resolve_role_file "$workspace" "$role"); then
    rel_path=$(_role_path_for_prompt "$workspace" "$role_file")
    cat <<EOF

## Your Role: $role

Before implementing, read \`$rel_path\` and follow its instructions for this task.
EOF
  else
    cat <<EOF

## Your Role: $role

Before implementing, find and read the role description file (try \`.ralph/roles/${role}.md\` or \`roles/${role}.md\`).
EOF
  fi
}

# =============================================================================
# PUBLIC: YAML IMPORT/EXPORT
# =============================================================================

# Check if YAML task file exists
has_yaml_tasks() {
  local workspace="${1:-.}"
  [[ -f "$workspace/.ralph/$TASK_CACHE_FILE" ]]
}

# Export current task state to YAML (for external tooling)
export_tasks_yaml() {
  local workspace="${1:-.}"
  
  # Force cache refresh
  rm -f "$workspace/.ralph/$TASK_MTIME_FILE"
  parse_tasks "$workspace" || return 1
  
  # Output the cache file
  cat "$workspace/.ralph/$TASK_CACHE_FILE"
}

# Import tasks from external YAML (advanced usage)
# This creates/updates RALPH_TASK.md from YAML
import_tasks_yaml() {
  local workspace="${1:-.}"
  local yaml_file="$2"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$yaml_file" ]]; then
    echo "ERROR: YAML file not found: $yaml_file" >&2
    return 1
  fi
  
  # For now, just copy to cache location
  # Full YAML->Markdown conversion would require more logic
  mkdir -p "$workspace/.ralph"
  cp "$yaml_file" "$workspace/.ralph/$TASK_CACHE_FILE"
  
  echo "Imported YAML to cache. Note: RALPH_TASK.md not modified." >&2
  echo "Use mark_task_complete/incomplete to sync changes." >&2
}

# =============================================================================
# PUBLIC: UTILITY FUNCTIONS
# =============================================================================

# Get progress as "done:total" format (compatible with existing count_criteria)
get_progress() {
  local workspace="${1:-.}"
  local done=$(count_completed "$workspace")
  local total=$(count_total "$workspace")
  echo "$done:$total"
}

# Check if all tasks are complete
is_all_complete() {
  local workspace="${1:-.}"
  local remaining=$(count_remaining "$workspace")
  [[ "$remaining" -eq 0 ]]
}

# Pretty print task status
print_task_status() {
  local workspace="${1:-.}"
  local done=$(count_completed "$workspace")
  local total=$(count_total "$workspace")
  local remaining=$((total - done))
  
  echo "Task Progress: $done / $total complete ($remaining remaining)"
  echo ""
  echo "Tasks:"
  
  get_all_tasks "$workspace" | while IFS='|' read -r id status desc; do
    local checkbox="[ ]"
    if [[ "$status" == "completed" ]]; then
      checkbox="[x]"
    fi
    echo "  $checkbox $desc (${id})"
  done
}

# =============================================================================
# CLI INTERFACE (when run directly)
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Script is being run directly, not sourced
  
  usage() {
    echo "Usage: $0 <command> [workspace] [args...]"
    echo ""
    echo "Commands:"
    echo "  parse           Parse tasks and update cache"
    echo "  list            List all tasks"
    echo "  next            Get next pending task"
    echo "  complete <id>   Mark task as complete"
    echo "  incomplete <id> Mark task as incomplete"
    echo "  count           Show task counts"
    echo "  status          Show pretty task status"
    echo "  export          Export tasks as YAML"
    echo "  import-plan F   Import checkboxes from plan markdown into RALPH_TASK.md"
    echo ""
    echo "Examples:"
    echo "  $0 list ."
    echo "  $0 next /path/to/project"
    echo "  $0 complete . line_15"
  }
  
  cmd="${1:-}"
  workspace="${2:-.}"
  
  case "$cmd" in
    parse)
      parse_tasks "$workspace"
      echo "Cache updated."
      ;;
    list)
      get_all_tasks "$workspace"
      ;;
    next)
      result=$(get_next_task "$workspace")
      if [[ -n "$result" ]]; then
        echo "$result"
      else
        echo "No pending tasks."
      fi
      ;;
    complete)
      task_id="${3:-}"
      if [[ -z "$task_id" ]]; then
        echo "ERROR: Task ID required" >&2
        exit 1
      fi
      mark_task_complete "$workspace" "$task_id"
      echo "Marked $task_id as complete."
      ;;
    incomplete)
      task_id="${3:-}"
      if [[ -z "$task_id" ]]; then
        echo "ERROR: Task ID required" >&2
        exit 1
      fi
      mark_task_incomplete "$workspace" "$task_id"
      echo "Marked $task_id as incomplete."
      ;;
    count)
      echo "Completed: $(count_completed "$workspace")"
      echo "Remaining: $(count_remaining "$workspace")"
      echo "Total:     $(count_total "$workspace")"
      ;;
    status)
      print_task_status "$workspace"
      ;;
    export)
      export_tasks_yaml "$workspace"
      ;;
    import-plan)
      plan_path="${3:-}"
      if [[ -z "$plan_path" ]]; then
        echo "ERROR: Plan file path required" >&2
        exit 1
      fi
      import_plan_to_ralph_task "$workspace" "$plan_path"
      echo "Imported plan checkboxes into RALPH_TASK.md"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
fi
