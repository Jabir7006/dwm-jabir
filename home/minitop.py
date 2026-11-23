#!/usr/bin/env python3
"""
MINITOP - Fast, clean terminal process monitor
- Memory: USS (unique) when available, else RSS
- Cached process scan → no lag on click/sort
- Process CPU% is per-core (can exceed system %)
"""
import curses
import psutil
import os
import signal
import time
from collections import defaultdict

# Column layout (fixed positions)
COL_NAME = 2
COL_PIDS = 34
COL_CPU  = 44
COL_RAM  = 58
NAME_WIDTH = 30

def get_cpu_temp():
    try:
        temps = psutil.sensors_temperatures()
        if not temps:
            return "N/A"
        for name in ('coretemp', 'k10temp', 'zenpower', 'nct6775', 'acpitz'):
            entries = temps.get(name)
            if entries:
                return f"{entries[0].current:.1f}°C"
        first = next(iter(temps.values()), None)
        return f"{first[0].current:.1f}°C" if first else "N/A"
    except Exception:
        return "N/A"

def format_bytes(b):
    b = float(b)
    for unit in ('B', 'K', 'M', 'G', 'T'):
        if b < 1024.0:
            return f"{b:.1f}{unit}"
        b /= 1024.0
    return f"{b:.1f}P"

def draw_text(stdscr, y, x, text, attr=0):
    max_y, max_x = stdscr.getmaxyx()
    if 0 <= y < max_y and 0 <= x < max_x:
        try:
            stdscr.addstr(y, x, str(text)[:max_x - x - 1], attr)
        except curses.error:
            pass

def draw_meter(stdscr, y, x, label, percent, width=18):
    filled = max(0, min(width, int((percent / 100.0) * width)))
    bar = f"[{'|' * filled}{' ' * (width - filled)}]"
    color = curses.color_pair(2)
    if percent > 85:
        color = curses.color_pair(3) | curses.A_BOLD
    elif percent > 60:
        color = curses.color_pair(5) | curses.A_BOLD
    draw_text(stdscr, y, x, f"{label:<4}")
    draw_text(stdscr, y, x + 5, bar, color)
    draw_text(stdscr, y, x + 5 + width + 1, f"{percent:5.1f}%")

def get_process_mem(p):
    """USS preferred (unique RAM). Fallback RSS."""
    try:
        mi = p.memory_full_info()
        uss = getattr(mi, 'uss', None)
        if uss is not None:
            return uss
        return mi.rss
    except Exception:
        try:
            return p.memory_info().rss
        except Exception:
            return 0

def collect_process_groups():
    groups = defaultdict(lambda: {'pids': [], 'cpu': 0.0, 'mem': 0})
    for p in psutil.process_iter(['pid', 'name']):
        try:
            with p.oneshot():
                name = p.info.get('name') or '?'
                cpu = p.cpu_percent(interval=None)
                mem = get_process_mem(p)
            groups[name]['pids'].append(p.info['pid'])
            groups[name]['cpu'] += cpu
            groups[name]['mem'] += mem
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue
        except Exception:
            continue
    return dict(groups)

def main(stdscr):
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_RED, -1)
    curses.init_pair(4, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(5, curses.COLOR_YELLOW, -1)
    curses.init_pair(6, curses.COLOR_MAGENTA, -1)

    curses.curs_set(0)
    stdscr.timeout(100)
    curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)

    BUTTON4 = getattr(curses, 'BUTTON4_PRESSED', 0x10000)
    BUTTON5 = getattr(curses, 'BUTTON5_PRESSED', 0x20000)

    sort_modes = ['NAME', 'CPU', 'RAM']
    current_sort = 1
    search_query = ""
    is_searching = False
    selected_idx = 0
    offset = 0

    REFRESH_SEC = 1.5
    groups = {}
    last_collect = 0.0
    cpu_total = 0.0
    mem = None
    disk = None
    temp = "N/A"
    filtered = []

    psutil.cpu_percent(interval=None)
    for p in psutil.process_iter(['pid']):
        try:
            p.cpu_percent(interval=None)
        except Exception:
            pass

    def refresh_data():
        nonlocal groups, last_collect, cpu_total, mem, disk, temp, filtered
        now = time.monotonic()
        if now - last_collect < REFRESH_SEC and groups:
            return
        last_collect = now
        cpu_total = psutil.cpu_percent(interval=None)
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        temp = get_cpu_temp()
        groups = collect_process_groups()
        rebuild_filtered()

    def rebuild_filtered():
        nonlocal filtered, selected_idx, offset
        q = search_query.lower()
        filtered = [(n, d) for n, d in groups.items() if not q or q in n.lower()]
        mode = sort_modes[current_sort]
        if mode == 'CPU':
            filtered.sort(key=lambda x: x[1]['cpu'], reverse=True)
        elif mode == 'RAM':
            filtered.sort(key=lambda x: x[1]['mem'], reverse=True)
        else:
            filtered.sort(key=lambda x: x[0].lower())
        n = len(filtered)
        if selected_idx >= n:
            selected_idx = max(0, n - 1)
        if selected_idx < offset:
            offset = selected_idx

    refresh_data()

    while True:
        max_y, max_x = stdscr.getmaxyx()
        refresh_data()

        if not filtered and groups:
            rebuild_filtered()

        n_items = len(filtered)
        list_height = max(1, max_y - 10)
        if selected_idx >= offset + list_height:
            offset = selected_idx - list_height + 1
        if offset < 0:
            offset = 0

        stdscr.erase()

        draw_text(stdscr, 0, 0, " MINITOP ".center(max_x, "="),
                  curses.color_pair(1) | curses.A_BOLD)

        if mem and disk:
            draw_meter(stdscr, 1, 2, "CPU", cpu_total)
            draw_text(stdscr, 1, 32, f"Temp: {temp}", curses.color_pair(5))
            draw_meter(stdscr, 2, 2, "RAM", mem.percent)
            draw_text(stdscr, 2, 32,
                      f"Used: {format_bytes(mem.used)} / {format_bytes(mem.total)}")
            draw_meter(stdscr, 3, 2, "SSD", disk.percent)
            draw_text(stdscr, 3, 32,
                      f"Free: {format_bytes(disk.free)} / {format_bytes(disk.total)}")

        search_disp = (f" Search: {search_query}_"
                       if is_searching else
                       f" Search: {search_query or '[Press / to type]'}")
        draw_text(stdscr, 4, 2, search_disp,
                  curses.color_pair(5) if is_searching else curses.color_pair(1))

        draw_text(stdscr, 5, 0, "-" * max_x, curses.color_pair(1))

        mode = sort_modes[current_sort]
        name_attr = curses.color_pair(6) | curses.A_BOLD if mode == 'NAME' else curses.color_pair(1)
        cpu_attr  = curses.color_pair(6) | curses.A_BOLD if mode == 'CPU'  else curses.color_pair(1)
        ram_attr  = curses.color_pair(6) | curses.A_BOLD if mode == 'RAM'  else curses.color_pair(1)

        draw_text(stdscr, 6, COL_NAME, "APPLICATION", name_attr)
        draw_text(stdscr, 6, COL_PIDS, "PIDS", curses.color_pair(1))
        draw_text(stdscr, 6, COL_CPU,  "CPU%", cpu_attr)
        draw_text(stdscr, 6, COL_RAM,  "RAM (USS)", ram_attr)
        draw_text(stdscr, 7, 0, "-" * max_x, curses.color_pair(1))

        for i, (name, data) in enumerate(filtered[offset:offset + list_height]):
            row_y = 8 + i
            name_str = (name[:NAME_WIDTH - 3] + '...') if len(name) > NAME_WIDTH else name
            is_sel = (i + offset == selected_idx) and not is_searching
            attr = curses.color_pair(4) | curses.A_BOLD if is_sel else 0

            if is_sel:
                try:
                    stdscr.addstr(row_y, 0, " " * (max_x - 1), attr)
                except curses.error:
                    pass

            draw_text(stdscr, row_y, COL_NAME, f"{name_str:<{NAME_WIDTH}}", attr)
            draw_text(stdscr, row_y, COL_PIDS, f"{len(data['pids']):>4}", attr)
            draw_text(stdscr, row_y, COL_CPU,  f"{data['cpu']:>6.1f}", attr)
            draw_text(stdscr, row_y, COL_RAM,  f"{format_bytes(data['mem']):>10}", attr)

        footer = ("↑↓/Scroll  Click=sort  / search  k kill  q quit  |  "
                  "CPU%=per-core  RAM=USS unique")
        draw_text(stdscr, max_y - 1, 0, footer.center(max_x)[:max_x - 1],
                  curses.color_pair(1) | curses.A_REVERSE)

        stdscr.refresh()

        key = stdscr.getch()
        if key == -1:
            continue

        if key == curses.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = curses.getmouse()
                if bstate & BUTTON4:
                    if selected_idx > 0:
                        selected_idx -= 1
                elif bstate & BUTTON5:
                    if selected_idx < n_items - 1:
                        selected_idx += 1
                elif bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED):
                    if my == 6:
                        if mx < COL_PIDS:
                            current_sort = 0
                        elif COL_CPU <= mx < COL_RAM:
                            current_sort = 1
                        elif mx >= COL_RAM:
                            current_sort = 2
                        rebuild_filtered()
                    elif 8 <= my < 8 + list_height:
                        clicked = offset + (my - 8)
                        if clicked < n_items:
                            selected_idx = clicked
            except curses.error:
                pass
            continue

        if is_searching:
            if key == 27:
                is_searching = False
                search_query = ""
                rebuild_filtered()
            elif key in (10, 13):
                is_searching = False
                rebuild_filtered()
            elif key in (curses.KEY_BACKSPACE, 8, 127):
                search_query = search_query[:-1]
                rebuild_filtered()
            elif 32 <= key <= 126:
                search_query += chr(key)
                rebuild_filtered()
            continue

        if key == ord('q'):
            break
        elif key == curses.KEY_UP:
            if selected_idx > 0:
                selected_idx -= 1
        elif key == curses.KEY_DOWN:
            if selected_idx < n_items - 1:
                selected_idx += 1
        elif key == ord('/'):
            is_searching = True
        elif key == ord('k') and filtered:
            app_name, app_data = filtered[selected_idx]
            msg = (f" KILL {len(app_data['pids'])}x '{app_name}'? (y/n) ").center(max_x)
            draw_text(stdscr, max_y - 1, 0, msg,
                      curses.color_pair(3) | curses.A_BOLD | curses.A_REVERSE)
            stdscr.refresh()
            stdscr.timeout(-1)
            if stdscr.getch() == ord('y'):
                for pid in app_data['pids']:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except OSError:
                        pass
                last_collect = 0
            stdscr.timeout(100)

if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass