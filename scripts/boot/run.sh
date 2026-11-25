#!/bin/bash
cd ~

tmux new-session -s my_session -d  -c ~

tmux split-window -h -t my_session
tmux split-window -v -t my_session:0.0
tmux split-window -v -t my_session:0.1
tmux split-window -v -t my_session:0.2
tmux split-window -v -t my_session:0.3

tmux send-keys -t my_session:0.4 'sleep 2 && sudo bash /home/gem/infimech/svc/svc_loop.sh klipper bash /home/gem/kp.sh' C-m
tmux send-keys -t my_session:0.1 'sudo bash /home/gem/infimech/svc/svc_loop.sh moonraker bash /home/gem/moon.sh' C-m
tmux send-keys -t my_session:0.2 'sudo nginx' C-m
tmux send-keys -t my_session:0.3 'sudo bash /home/gem/infimech/svc/svc_loop.sh klipper_mcu bash /home/gem/local_mcu.sh' C-m

tmux attach-session -t my_session

