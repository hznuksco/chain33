#!/usr/bin/env bash

set -e
set -o pipefail
set -o verbose
set -o xtrace

# os: ubuntu16.04 x64
# first, you must install jq tool of json
# sudo apt-get install jq
# sudo apt-get install shellcheck, in order to static check shell script
# sudo apt-get install parallel
# ./docker-compose.sh build

PWD=$(cd "$(dirname "$0")" && pwd)
export PATH="$PWD:$PATH"
CLI=" docker exec ${1}_chain33_1 /root/chain33-cli"
NODE3="${1}_chain33_1"
CLI="docker exec ${NODE3} /root/chain33-cli"

NODE2="${1}_chain32_1"
CLI2="docker exec ${NODE2} /root/chain33-cli"

sedfix=""
if [ "$(uname)" == "Darwin" ]; then
    sedfix=".bak"
fi

function init() {
    # update test environment
    sed -i $sedfix 's/^Title.*/Title="local"/g' chain33.toml
    sed -i $sedfix 's/^TestNet=.*/TestNet=true/g' chain33.toml

    # p2p
    sed -i $sedfix 's/^seeds=.*/seeds=["chain33:13802","chain32:13802","chain31:13802"]/g' chain33.toml
    sed -i $sedfix 's/^enable=.*/enable=true/g' chain33.toml
    sed -i $sedfix 's/^isSeed=.*/isSeed=true/g' chain33.toml
    sed -i $sedfix 's/^innerSeedEnable=.*/innerSeedEnable=false/g' chain33.toml
    sed -i $sedfix 's/^useGithub=.*/useGithub=false/g' chain33.toml

    # rpc
    sed -i $sedfix 's/^jrpcBindAddr=.*/jrpcBindAddr="0.0.0.0:8801"/g' chain33.toml
    sed -i $sedfix 's/^grpcBindAddr=.*/grpcBindAddr="0.0.0.0:8802"/g' chain33.toml
    sed -i $sedfix 's/^whitlist=.*/whitlist=["localhost","127.0.0.1","0.0.0.0"]/g' chain33.toml

    # wallet
    sed -i $sedfix 's/^minerdisable=.*/minerdisable=false/g' chain33.toml

    # docker-compose ps
    docker-compose ps

	# remove exsit container
	docker-compose down

	# create and run docker-compose container
	docker-compose up --build -d


    local SLEEP=60
    echo "=========== sleep ${SLEEP}s ============="
    sleep ${SLEEP}

	# docker-compose ps
	docker-compose ps

	# query node run status
	${CLI} block last_header
	${CLI} net info

	${CLI} net peer_info
	peersCount=$(${CLI} net peer_info | jq '.[] | length')
	echo "${peersCount}"
	if [ "${peersCount}" -lt 2 ]; then
		echo "peers error"
		exit 1
	fi

	#echo "=========== # create seed for wallet ============="
	#seed=$(${CLI} seed generate -l 0 | jq ".seed")
	#if [ -z "${seed}" ]; then
	#    echo "create seed error"
	#    exit 1
	#fi

	echo "=========== # save seed to wallet ============="
	result=$(${CLI} seed save -p 1314 -s "tortoise main civil member grace happy century convince father cage beach hip maid merry rib" | jq ".isok")
	if [ "${result}" = "false" ]; then
		echo "save seed to wallet error seed, result: ${result}"
		exit 1
	fi

	sleep 2

	echo "=========== # unlock wallet ============="
	result=$(${CLI} wallet unlock -p 1314 -t 0 | jq ".isok")
	if [ "${result}" = "false" ]; then
		exit 1
	fi

	sleep 2

	echo "=========== # import private key returnAddr ============="
	result=$(${CLI} account import_key -k CC38546E9E659D15E6B4893F0AB32A06D103931A8230B0BDE71459D2B27D6944 -l returnAddr | jq ".label")
	echo "${result}"
	if [ -z "${result}" ]; then
		exit 1
	fi

	sleep 2

	echo "=========== # import private key mining ============="
	result=$(${CLI} account import_key -k 4257D8692EF7FE13C68B65D6A52F03933DB2FA5CE8FAF210B5B8B80C721CED01 -l minerAddr | jq ".label")
	echo "${result}"
	if [ -z "${result}" ]; then
		exit 1
	fi

	sleep 2
	echo "=========== # close auto mining ============="
	result=$(${CLI} wallet auto_mine -f 0 | jq ".isok")
	if [ "${result}" = "false" ]; then
		exit 1
	fi

	echo "=========== sleep ${SLEEP}s ============="
	sleep ${SLEEP}

	echo "=========== check genesis hash ========== "
	${CLI} block hash -t 0
	res=$(${CLI} block hash -t 0 | jq ".hash")
	count=$(echo "$res" | grep -c "0x67c58d6ba9175313f0468ae4e0ddec946549af7748037c2fdd5d54298afd20b6")
	if [ "${count}" != 1 ]; then
		echo "genesis hash error!"
		exit 1
	fi

	echo "=========== query height ========== "
	${CLI} block last_header
	result=$(${CLI} block last_header | jq ".height")
	if [ "${result}" -lt 1 ]; then
		exit 1
	fi

	sync_status "${CLI}"

	${CLI} wallet status
	${CLI} account list
	${CLI} mempool list
	# ${CLI} mempool last_txs
}

function block_wait() {
    if [ "$#" -lt 2 ]; then
        echo "wrong block_wait params"
        exit 1
    fi
    cur_height=$(${1} block last_header | jq ".height")
    expect=$((cur_height + ${2}))
    count=0
    while true; do
        new_height=$(${1} block last_header | jq ".height")
        if [ "${new_height}" -ge "${expect}" ]; then
            break
        fi
        count=$((count + 1))
        sleep 1
    done
    echo "wait new block $count s"
}


function sync_status(){
    echo "=========== query sync status========== "
    local sync_status
    sync_status=$(${1} net is_sync)
    if [ "${sync_status}" = "false" ]; then
        ${1} block last_header
        exit 1
    fi

	echo "=========== query clock sync status========== "
	sync_status=$(${1} net is_clock_sync)
	if [ "${sync_status}" = "false" ]; then
		exit 1
	fi
}

function sync() {
	echo "=========== stop  ${NODE2} node========== "
	docker stop "${NODE2}"
	sleep 20

	echo "=========== start ${NODE2} node========== "
	docker start "${NODE2}"

	for i in $(seq 20); do
		sleep 1
		${CLI2} net is_sync
		${CLI2} block last_header
	done

	sync_status "${CLI2}"
}

function transfer(){
    echo "=========== # transfer ============="
    hashes=()
    for ((i = 0; i < 10; i++)); do
        hash=$(${CLI} send bty transfer -a 1 -n test -t 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt -k 4257D8692EF7FE13C68B65D6A52F03933DB2FA5CE8FAF210B5B8B80C721CED01)
        hashes=("${hashes[@]}" "$hash")
    done
    block_wait "${CLI}" 1
    echo "len: ${#hashes[@]}"
    if [ "${#hashes[@]}" != 10 ]; then
        echo "tx number wrong"
        exit 1
    fi

    for ((i = 0; i < ${#hashes[*]}; i++)); do
        txs=$(${CLI} tx query_hash -s "${hashes[$i]}" | jq ".txs")
        if [ -z "${txs}" ]; then
            echo "cannot find tx"
            exit 1
        fi
    done

    echo "=========== # withdraw ============="
    hash=$(${CLI} send bty transfer -a 2 -n deposit -t 1wvmD6RNHzwhY4eN75WnM6JcaAvNQ4nHx -k CC38546E9E659D15E6B4893F0AB32A06D103931A8230B0BDE71459D2B27D6944)
    echo "${hash}"
    block_wait "${CLI}" 1
    before=$(${CLI} account balance -a 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt -e retrieve | jq -r ".balance")
    if [ "${before}" == "0.0000" ]; then
        echo "wrong ticket balance, should not be zero"
        exit 1
    fi

    hash=$(${CLI} send bty withdraw -a 1 -n withdraw -e retrieve -k CC38546E9E659D15E6B4893F0AB32A06D103931A8230B0BDE71459D2B27D6944)
    echo "${hash}"
    block_wait "${CLI}" 1
    txs=$(${CLI} tx query_hash -s "${hash}" | jq ".txs")
    if [ "${txs}" == "null" ]; then
        echo "withdraw cannot find tx"
        exit 1
    fi
}


function relay_before() {
	sed -i 's/ForkV7AddRelay.*/ForkV7AddRelay = 2/g' ../types/relay.go
}

function relay_after() {
	git checkout ../types/relay.go
}

function relay() {
	echo "================relayd========================"
	while true; do
		${1} block last_header
		result=$(${1} block last_header | jq ".height")
		if [ "${result}" -gt 10 ]; then
			break
		fi
		sleep 1
	done

	${1} relay btc_cur_height
	result=$(${1} relay btc_cur_height | jq ".BaseHeight")
	if [ "${result}" != 99900 ]; then
	    echo "height not correct"
	    #exit 1
	fi

	echo "=========== # transfer to relay ============="
	hash=$(${1} send bty transfer -a 1000 -t 1rhRgzbz264eyJu7Ac63wepsm9TsEpwXM -n "send to relay" -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
	echo "${hash}"
	sleep 20
	before=$(${CLI} account balance -a 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv -e relay | jq ".balance")
	before=$(echo "$before" | bc)
	if [ "${before}" == 0.0000 ]; then
		echo "wrong relay balance, should not be zero"
		exit 1
	fi

	echo "=========== # transfer to accept addr ============="
	hash=$(${1} send bty transfer -a 1000 -t 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt -n "send to relay" -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
	echo "${hash}"
	sleep 20
	before=$(${CLI} account balance -a 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt -e coins | jq ".balance")
	before=$(echo "$before" | bc)
	if [ "${before}" == 0.0000 ]; then
		echo "wrong relay balance, should not be zero"
		exit 1
	fi

	echo "=========== # create order ============="
	hash=$(${1} send relay create -o 0 -c BTC -a 1Am9UTGfdnxabvcywYG2hvzr6qK8T3oUZT -m 2.99 -f 0.02 -b 200 -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
	echo "${hash}"
	sleep 20
	${CLI} tx query -s ${hash}
	coinaddr=$(${CLI} tx query -s ${hash} | jq ".coinAddr")
	coinaddr=$(echo "coinaddr" | bc)
	if [ "${coinaddr}x" != "1Am9UTGfdnxabvcywYG2hvzr6qK8T3oUZTx" ]; then
		echo "wrong create order to coinaddr"
		#exit 1
	fi
	${CLI} relay status -s 1
	orderid=$(${CLI} relay status -s 1 | jq -r ".orderid")
	status=$(${CLI} relay status -s 1 | jq -r ".status")
	if [ "${status}x" != "pendingx" ]; then
	    echo "wrong relay order pending status"
	    exit 1
	fi
    coinoperation=$(${CLI} relay status -s 1 | jq -r ".coinoperation")
    if [ "${coinoperation}x" != "buyx" ]; then
        echo "wrong relay order sell operation"
        exit 1
    fi

	echo "=========== # accept order ============="
	hash=$(${1} send relay accept -f 0.001 -o ${orderid} -a 1Am9UTGfdnxabvcywYG2hvzr6qK8T3oUZT -k 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt)
	echo "${hash}"
	sleep 20
	${CLI} tx query -s ${hash}

    ${CLI} relay status -s 2
	status=$(${CLI} relay status -s 2 | jq -r ".status")
	if [ "${status}x" != "lockingx" ]; then
	    echo "wrong relay order locking status"
	    exit 1
	fi

	echo "=========== # confirm order ============="
	hash=$(${1} send relay confirm -f 0.001 -t 6359f0868171b1d194cbee1af2f16ea598ae8fad666d9b012c8ed2b79a236ec4 -o ${orderid} -k 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt)
	echo "${hash}"
	sleep 20
	${CLI} tx query -s ${hash}

    ${CLI} relay status -s 3
	status=$(${CLI} relay status -s 3 | jq -r ".status")
	if [ "${status}x" != "confirmingx" -a "${status}x" != "finishedx" ]; then
	    echo "wrong relay order confirming or finished status"
	    exit 1
	fi

    echo "=========== # test cancel create order ==="
	echo "=========== # create order ============="
	hash=$(${1} send relay create -o 0 -c BTC -a 1Am9UTGfdnxabvcywYG2hvzr6qK8T3oUZT -m 2.99 -f 0.02 -b 200 -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
	echo "${hash}"
	sleep 20
	${CLI} tx query -s ${hash}

	${CLI} relay status -s 1
	orderid=$(${CLI} relay status -s 1 | jq -r ".orderid")
	status=$(${CLI} relay status -s 1 | jq -r ".status")
	if [ "${status}x" != "pendingx" ]; then
	    echo "wrong relay order pending status"
	    exit 1
	fi

	echo "=========== # cancel order ============="
	hash=$(${1} send relay revoke -a 1 -t 0 -f 0.01 -i ${orderid} -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
	echo "${hash}"
	sleep 20
	${CLI} tx query -s ${hash}

	${CLI} relay status -s 0
	status=$(${CLI} relay status -s 0 | jq -r ".status")
	if [ "${status}x" != "initx" ]; then
	    echo "wrong relay order pending status"
	    exit 1
	fi

    echo "=========== # test create unlock order ==="
	echo "=========== # create order ============="
	hash=$(${1} send relay create -o 0 -c BTC -a 1Am9UTGfdnxabvcywYG2hvzr6qK8T3oUZT -m 2.99 -f 0.02 -b 200 -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
	echo "${hash}"
	sleep 20
	${CLI} tx query -s ${hash}

	${CLI} relay status -s 1
	orderid=$(${CLI} relay status -s 1 | jq -r ".orderid")
	status=$(${CLI} relay status -s 1 | jq -r ".status")
	if [ "${status}x" != "pendingx" ]; then
	    echo "wrong relay order pending status"
	    exit 1
	fi

	echo "=========== # unlock order ============="
	hash=$(${1} send relay revoke -a 0 -t 0 -f 0.01 -i ${orderid} -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
	echo "${hash}"
	sleep 20
	${CLI} tx query -s ${hash}

	${CLI} relay status -s 5
	status=$(${CLI} relay status -s 5 | jq -r ".status")
	if [ "${status}x" != "canceledx" ]; then
	    echo "wrong relay order canceled status"
	    exit 1
	fi

    echo "=========== # test create sell order ==="
    echo "=========== # create order ============="
    hash=$(${1} send relay create -o 1 -c BTC -a 1Am9UTGfdnxabvcywYG2hvzr6qK8T3oUZT -m 2.99 -f 0.02 -b 200 -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
    echo "${hash}"
    sleep 20
    ${CLI} tx query -s ${hash}

    ${CLI} relay status -s 1
    orderid=$(${CLI} relay status -s 1 | jq -r ".orderid")
    status=$(${CLI} relay status -s 1 | jq -r ".status")
    if [ "${status}x" != "pendingx" ]; then
        echo "wrong relay order pending status"
        exit 1
    fi

    coinoperation=$(${CLI} relay status -s 1 | jq -r ".coinoperation")
    if [ "${coinoperation}x" != "sellx" ]; then
        echo "wrong relay order sell operation"
        exit 1
    fi

	echo "=========== # transfer to relay ============="
	hash=$(${1} send bty transfer -a 300 -t 1rhRgzbz264eyJu7Ac63wepsm9TsEpwXM -n "send to relay" -k 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt)
	echo "${hash}"
	sleep 20
	before=$(${CLI} account balance -a 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt -e relay | jq ".balance")
	before=$(echo "$before" | bc)
	if [ "${before}" == 0.0000 ]; then
		echo "wrong relay balance, should not be zero"
		exit 1
	fi

    echo "=========== # accept order ============="
    hash=$(${1} send relay accept -f 0.001 -o ${orderid} -a 1Am9UTGfdnxabvcywYG2hvzr6qK8T3oUZT -k 14KEKbYtKKQm4wMthSK9J4La4nAiidGozt)
    echo "${hash}"
    sleep 20
    ${CLI} tx query -s ${hash}

    ${CLI} relay status -s 2
    status=$(${CLI} relay status -s 2 | jq -r ".status")
    if [ "${status}x" != "lockingx" ]; then
        echo "wrong relay order locking status"
        exit 1
    fi

    echo "=========== # confirm order ============="
    hash=$(${1} send relay confirm -f 0.001 -t 6359f0868171b1d194cbee1af2f16ea598ae8fad666d9b012c8ed2b79a236ec4 -o ${orderid} -k 12qyocayNF7Lv6C9qW4avxs2E7U41fKSfv)
    echo "${hash}"
    sleep 20
    ${CLI} tx query -s ${hash}
    rst=$(${CLI} tx query -s ${hash} | jq -r ".receipt.logs[1].log")
    if [ "${rst}x" != "ErrRelayCoinTxHashUsed" ]; then
        echo "wrong relay order result"
        exit 1
    fi

    ## time limited, the following cases could not be added to CI currently, except add test macro to lock time
    #echo "=========== # test finish order ==="
    #echo "=========== # test creator unlock accepted order ==="
    #echo "=========== # test acceptor unlock accepted order ==="
    #echo "=========== # test creator unlock confirmed order ==="
    #echo "=========== # test acceptor unlock confirmed order ==="
}

function main() {
	echo "==========================================main begin========================================================"
	init
	sync
	#transfer
	relay "${CLI}"

	# TODO other work!!!
	echo "==========================================main end========================================================="
}

# run script
main
