#!/bin/bash
# Convenience script for managing Communion services

case "$1" in
    start)
        echo "Starting Communion services..."
        sudo systemctl start communion-python communion-sc
        sleep 2
        sudo systemctl status communion-python communion-sc --no-pager
        ;;
    stop)
        echo "Stopping Communion services..."
        sudo systemctl stop communion-python communion-sc
        ;;
    restart)
        echo "Restarting Communion services..."
        sudo systemctl restart communion-python communion-sc
        sleep 2
        sudo systemctl status communion-python communion-sc --no-pager
        ;;
    status)
        sudo systemctl status communion-python communion-sc --no-pager
        ;;
    logs)
        # Default to python logs, or specify: ./manage.sh logs sc
        if [ "$2" == "sc" ]; then
            journalctl -u communion-sc -f
        else
            journalctl -u communion-python -f
        fi
        ;;
    logs-both)
        journalctl -u communion-python -u communion-sc -f
        ;;
    enable)
        echo "Enabling auto-start on boot..."
        sudo systemctl enable communion-python communion-sc
        ;;
    disable)
        echo "Disabling auto-start on boot..."
        sudo systemctl disable communion-python communion-sc
        ;;
    *)
        echo "Communion Service Manager"
        echo ""
        echo "Usage: $0 {start|stop|restart|status|logs|logs-both|enable|disable}"
        echo ""
        echo "Commands:"
        echo "  start      - Start both services"
        echo "  stop       - Stop both services"
        echo "  restart    - Restart both services (use after code changes)"
        echo "  status     - Show status of both services"
        echo "  logs       - Tail Python logs (add 'sc' for SuperCollider)"
        echo "  logs-both  - Tail both logs together"
        echo "  enable     - Enable auto-start on boot"
        echo "  disable    - Disable auto-start on boot"
        echo ""
        echo "Examples:"
        echo "  $0 start"
        echo "  $0 logs sc"
        echo "  $0 restart"
        exit 1
        ;;
esac
