#!/bin/bash
#
#
#

hostname=$(hostnamectl | grep "Static hostname" | awk '{print $3}')



# echo "date hostname, nic, rxbytes, delta;rxpkts, delta;drop, detlta;txbytes,delta; txpkts,delta"
printf "%20s %15s %15s %10s %10s %10s %5s %10s %5s %10s %10s %10s %5s \n" "time" "host" "nic:" "rxbytes" "delta" "rxpkts" "delta" "drop" "delta" "txbytes" "delta" "txpkts" "delta" 

net_v2=0; net_v3=0; net_v5=0; net_v10=0; net_v11=0
rdma_v4=0; rdma_v12=0; rdma_v18=0; rdma_v26=0

while true
do
    if [[ $net_v2 -gt 0 ]]; then
        printf "%20s %15s " "$(date +"%Y%m%d%H%M%S")" "$hostname"
    fi
    
    read d1 d2 d3 d5 d10 d11 <<< $(cat /proc/net/dev | grep "lo" | awk '{print $1, $2, $3, $5, $10, $11}')
    if [[ $net_v2 -gt 0 ]]; then
        printf "%15s %10d %10d %10d %5d %10d %5d %10d %10d %10d %5d\n" "$d1" "$d2" "$((d2-net_v2))" "$d3" "$((d3-net_v3))" "$d5" "$((d5-net_v5))" "$d10" "$((d10-net_v10))" "$d11" "$((d11-net_v11))"
    fi
    
    # read r2 r4 r12 r18 r26 <<< $(rdma statistic | grep "rocep181s0f0" | awk '{print $2, $4, $12, $18, $26}')
    # if [[ $net_v2 -gt 0 ]]; then
    #     printf " %15s %10d %10d %10d %10d %10d %10d %10d %10d\n" "$r2" "$r4" "$((r4-rdma_v4))" "$r12" "$((r12-rdma_v12))" "$r18" "$((r18-rdma_v18))" "$r26" "$((r26-rdma_v26))"
    # fi

    net_v2=$d2; net_v3=$d3; net_v5=$d5; net_v10=$d10; net_v11=$d11
    rdma_v4=$r4; rdma_v12=$r12; rdma_v18=$r18; rdma_v26=$r26

    sleep 5
done


