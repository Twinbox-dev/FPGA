#!/usr/bin/env bash
# 全量回归：7 张测试卡并行仿真（每卡独立进程），最后汇总 PASS/FAIL 与墙钟。
# 用法: scripts/run_all_sims.sh            （在仓库根目录；16 核机器约 1 分钟）
#       make -C boardtest regress          （先增量构建再跑）
# 卡清单与 img/ 对应；单卡日志 boardtest/logs/<卡名>.log。
set -uo pipefail
cd "$(dirname "$0")/.."

SIM=boardtest/build_board/sim_board
CARDS="card card_mbr card_empty card_frag card_diag card_user card_user_2wav"
mkdir -p boardtest/logs

[ -x "$SIM" ] || { echo "先 make -C boardtest"; exit 1; }

pids=()
for c in $CARDS; do
    # 自动轮播用例（S7）只在主卡开：多卡都跑会把全量墙钟拉长一截
    if [ "$c" = card ]; then
        ( SIM_AUTO=1 "$SIM" "img/$c.img" > "boardtest/logs/$c.log" 2>&1 ) &
    else
        ( "$SIM" "img/$c.img" > "boardtest/logs/$c.log" 2>&1 ) &
    fi
    pids+=($!)
done

rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done

echo "================ 汇总 ================"
for c in $CARDS; do
    line=$(grep -E "=====" "boardtest/logs/$c.log" | tail -1)
    fails=$(grep -c "FAIL" "boardtest/logs/$c.log")
    printf "%-16s FAIL=%s  %s\n" "$c" "$fails" "$line"
done
[ "$rc" = 0 ] && echo "全量回归通过" || { echo "存在失败，看 boardtest/logs/"; exit 1; }
