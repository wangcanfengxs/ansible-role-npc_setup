#! /bin/bash

plan_resources(){
	local STAGE="$1" INPUT_EXPECTED="$2" INPUT_ACTUAL="$3" STAGE_MAPPER="$4"
	local LINE NAME
	while read -r LINE; do
		local NAMES=($(eval "echo $(jq -r '.name|sub("^\\*\\:"; "")'<<<"$LINE")")) NAME_INDEX=0
		for NAME in "${NAMES[@]}"; do
			[ ! -z "$NAME" ] || continue
			while read -r STM_LINE; do 
				jq_check 'length>1 and (.[1]|strings|startswith("*:"))'<<<"$STM_LINE" || {
					echo "$STM_LINE" && continue
				}
				local STM_VALS=($(eval "echo $(jq -r '.[1]|sub("^\\*\\:"; "")'<<<"$STM_LINE")")) STM_VAL_INDEX=0
				for STM_VAL in "${STM_VALS[@]}"; do
					(( STM_VAL_INDEX++ == NAME_INDEX % ${#STM_VALS[@]} )) \
						&& STM_VAL="$STM_VAL" jq -c '[.[0],env.STM_VAL]' <<<"$STM_LINE"
				done 
			done < <(NAME="$NAME" jq --argjson index "$((NAME_INDEX))" -c '. + {name:env.NAME, name_index:$index}|tostream'<<<"$LINE") \
				| jq -s 'fromstream(.[])'; ((NAME_INDEX++))
		done
	done < <(jq -c 'arrays[]' $INPUT_EXPECTED || >>$STAGE.error) \
		| jq -sc 'map({ key:.name, value:. }) | from_entries' >$STAGE.expected \
		&& [ ! -f $STAGE.error ] && jq_check 'objects' $STAGE.expected \
		&& jq -c 'arrays| map({ key:.name, value:. }) | from_entries' $INPUT_ACTUAL >$STAGE.actual \
		&& [ ! -f $STAGE.error ] && jq_check 'objects' $STAGE.actual \
		|| {
			rm -f $STAGE.*
			return 1
		}
	jq -sce '(.[0] | map_values({
				present: true,
				actual_present: false
			} + .)) * (.[1] | map_values(. + {
				actual_present: true
			})) 
		| map_values(. + {
			create: (.present and (.actual_present|not)),
			update: (.present and .actual_present),
			destroy : (.present == false and .actual_present),
			absent : (.present == null and .actual_present)
		}'"${STAGE_MAPPER:+| $STAGE_MAPPER}"')' $STAGE.expected $STAGE.actual >$STAGE \
		&& rm -f $STAGE.* || return 1
	jq -ce '.[]|select((.absent|not) and .error)|.error' $STAGE >&2 && return 1
	jq -ce '.[]|select(.absent)' $STAGE > $STAGE.omit || rm -f $STAGE.omit
	jq -ce '.[]|select(.create)' $STAGE > $STAGE.creating || rm -f $STAGE.creating
	jq -ce '.[]|select(.update)' $STAGE > $STAGE.updating || rm -f $STAGE.updating
	jq -ce '.[]|select(.destroy)' $STAGE > $STAGE.destroying || rm -f $STAGE.destroying
}

report_resources(){
	local RESOURCES=() ARG REPORT_SUMMARY REPORT_FILTER
	while ARG="$1" && shift; do
		case "$ARG" in
		--summary)
			REPORT_SUMMARY='Y'
			;;
		--report)
			REPORT_FILTER="$1" && shift
			;;
		*)
			RESOURCES=("${RESOURCES[@]}" "$ARG")
			;;
		esac
	done
	
	do_report(){
		local RESOURCE="$1" STAGE="$NPC_STAGE/$1"
		local RESOURCE_FILTER="{$RESOURCE:([{key:.name,value:.}]|from_entries)}"
		[ -f $STAGE ] && {
			jq -nc "{ $RESOURCE:{} }"
			jq -c ".[]|select(.actual_present and (.create or .update or .destroy or .absent | not))|$RESOURCE_FILTER" $STAGE
			[ -f $STAGE.creating ] && if [ ! -f $STAGE.created ]; then
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{creating: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.creating
			else
				jq -c '.+{change_action:"created"}|'"$RESOURCE_FILTER" $STAGE.created
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{created: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.created
			fi
			[ -f $STAGE.updating ] && if [ ! -f $STAGE.updated ]; then
				jq -c '.+{change_action:"updating"}|'"$RESOURCE_FILTER" $STAGE.updating
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{updating: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.updating
			else
				jq -c '.+{change_action:"updated"}|'"$RESOURCE_FILTER" $STAGE.updated
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{updated: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.updated
			fi
			[ -f $STAGE.destroying ] && if [ ! -f $STAGE.destroyed ]; then
				jq -c '.+{change_action:"destroying"}|'"$RESOURCE_FILTER" $STAGE.destroying
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{destroying: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.destroying
			else
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{destroyed: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.destroyed
			fi
			# [ -f $STAGE.omit ] && jq -c '.+{change_action:"omit"}|'"{$RESOURCE:[.]}" $STAGE.omit
		}
	}
	
	local RESOURCE REDUCE_FILTER
	for RESOURCE in "${RESOURCES[@]}"; do
		REDUCE_FILTER="$REDUCE_FILTER $RESOURCE: (if \$item.$RESOURCE then ((.$RESOURCE//{}) + \$item.$RESOURCE) else .$RESOURCE end),"
	done
	[ ! -z "$REPORT_SUMMARY" ] && {
		REDUCE_FILTER="$REDUCE_FILTER"'
			creating: (if $item.creating then ((.creating//[]) + $item.creating) else .creating end),
			updating: (if $item.updating then ((.updating//[]) + $item.updating) else .updating end),
			destroying: (if $item.destroying then ((.destroying//[]) + $item.destroying) else .destroying end),
			created: (if $item.created then ((.created//[]) + $item.created) else .created end),
			updated: (if $item.updated then ((.updated//[]) + $item.updated) else .updated end),
			destroyed: (if $item.destroyed then ((.destroyed//[]) + $item.destroyed) else .destroyed end)' \
		REPORT_FILTER='| with_entries(select(.value))) | . + { 
			changing: (.creating or .updating or .destroying), 
			changed: (.created or .updated or .destroyed)
			}'"$REPORT_FILTER"
	}
	{
		for RESOURCE in "${RESOURCES[@]}"; do
			do_report "$RESOURCE"
		done
		return 0	
	} | jq -sc 'reduce .[] as $item ( {}; {'"$REDUCE_FILTER"'}'"$REPORT_FILTER"
}

apply_actions(){
	local ACTION="$1" INPUT="$2" RESULT="$3" FORK=0 && [ -f $INPUT ] || return 0
	touch $RESULT && ( exec 99<$INPUT
		for FORK in $(seq 1 ${NPC_ACTION_FORKS:-1}); do
			[ ! -z "$FORK" ] && rm -f $RESULT.$FORK || continue
			while [ -f $RESULT ]; do
				flock 99 && read -r ACTION_ITEM <&99 && flock -u 99 || break
				$ACTION "$ACTION_ITEM" "$RESULT.$FORK" "$SECONDS $RESULT" && {
					[ -f "$RESULT.$FORK" ] || echo "$ACTION_ITEM" >"$RESULT.$FORK"
					flock 99 && jq -ce '.' $RESULT.$FORK >>$RESULT && flock -u 99 && continue
				}
				rm -f "$RESULT.$FORK"; rm -f $RESULT; break
			done &
		done; wait )
	[ -f $RESULT ] && rm -f $RESULT.* && return 0
	return 1
}

time_to_seconds(){
	local SEC="$1"; 
	[[ "$SEC" = *s ]] && SEC="${SEC%s}"
	[[ "$SEC" = *m ]] && SEC="${SEC%m}" && ((SEC *= 60))
	echo "$SEC"
}

action_check_continue(){
	local START RESULT TIMEOUT="$(time_to_seconds "${2:-$NPC_ACTION_TIMEOUT}")"
	read -r START RESULT _<<<"$1"|| return 1
	(( SECONDS - START < TIMEOUT )) || {
		echo "[ERROR] timeout" >&2
		return 1
	}
	[ ! -f $RESULT ] && {
		echo "[ERROR] cancel" >&2
		return 1
	}
	return 0
}

action_sleep(){
	local WAIT_SECONDS="$(time_to_seconds "$1")" && shift;
	while action_check_continue "$@"; do
		(( WAIT_SECONDS-- > 0 )) || return 0; sleep 1s
	done; return 1
}

jq_check(){
	local ARGS=() ARG OUTPUT
	while ARG="$1" && shift; do
		case "$ARG" in
		--out|--output)
			OUTPUT="$1" && shift
			;;
		--stdout)
			OUTPUT="/dev/fd/1"
			;;
		--stderr)
			OUTPUT="/dev/fd/2"
			;;
		*)
			ARGS=("${ARGS[@]}" "$ARG")
			;;
		esac
	done
	local CHECK_RESULT="$(jq "${ARGS[@]}")" && [ ! -z "$CHECK_RESULT" ] \
		&& jq -cre 'select(.)'<<<"$CHECK_RESULT" >${OUTPUT:-/dev/null} && return 0
	[ ! -z "$OUTPUT" ] && [ -f "$OUTPUT" ] && rm -f "$OUTPUT"
	return 1
}

checked_api(){
	local FILTER ARGS=(); while ! [[ "$1" =~ ^(GET|POST|PUT|DELETE|HEAD)$ ]]; do
		[ ! -z "$FILTER" ] && ARGS=("${ARGS[@]}" "$FILTER")
		FILTER="$1" && shift
	done; ARGS=("${ARGS[@]}" "$@")
	local RESPONSE="$(npc api --error "${ARGS[@]}")" && [ ! -z "$RESPONSE" ] || {
		[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] No response." >&2
		return 1
	}
	jq_check .code <<<"$RESPONSE" && [ "$(jq -r .code <<<"$RESPONSE")" != "200" ] && {
		[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] $RESPONSE" >&2
		return 1
	}
	if [ ! -z "$FILTER" ]; then
		jq -ce "($FILTER)//empty" <<<"$RESPONSE" && return 0
	else
		jq_check '.' <<<"$RESPONSE" && return 0
	fi
	[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] $RESPONSE" >&2
	return 1
}


load_instances(){
	local PAGE_SIZE=50 PAGE_NUM=1 FILTER="${1:-.}"
	while (( PAGE_SIZE > 0 )); do
		local PARAMS="pageSize=$PAGE_SIZE&pageNum=$PAGE_NUM" && PAGE_SIZE=0
		while read -r INSTANCE_ENTRY; do
			PAGE_SIZE=50 && jq -c "select(.)|$FILTER"<<<"$INSTANCE_ENTRY"
		done < <(npc api 'json.instances[]' GET "/api/v1/vm/allInstanceInfo?$PARAMS") 
		(( PAGE_NUM += 1 ))
	done | jq -sc '.'
	return 0
}
