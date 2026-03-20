#!/usr/bin/env python3
"""
SnakeMergeAnnotation - Web Interface for Snakemake
"""
import subprocess
import sys
import os
from pathlib import Path
from datetime import datetime

def install_dependencies_first_run():
    """Installs dependencies only on first run"""
    flag_file = '.dependencies_installed'
    
    if not os.path.exists(flag_file):
        print("\n" + "="*60)
        print("FIRST RUN - INSTALLING DEPENDENCIES")
        print("="*60)
        
        dependencies = [
            'flask>=2.0.0',
            'pyyaml>=5.4.0',
            'psutil>=5.8.0',
        ]
        
        for dep in dependencies:
            try:
                print(f"Installing {dep}...", end='', flush=True)
                subprocess.check_call(
                    [sys.executable, '-m', 'pip', 'install', '--quiet', dep],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                print(" OK")
            except Exception as e:
                print(f" ERROR: {e}")
        
        with open(flag_file, 'w') as f:
            f.write(f"Dependencies installed in: {datetime.now()}\n")
        
        print(" Installation complete!\n")
    else:
        print(" Dependencies already installed")

# ===== RUN INSTALLATION BEFORE IMPORTS =====
install_dependencies_first_run()

from flask import Flask, render_template, request, jsonify, send_file, send_from_directory
import yaml
import os
import subprocess
import threading
import time
from datetime import datetime
import re
import signal
import psutil
import tkinter as tk
from tkinter import filedialog
import logging

# ===== SILENT LOGGING CONFIGURATION =====
# Disable Flask request logs
log = logging.getLogger('werkzeug')
log.setLevel(logging.ERROR)

# Configure handler to show only critical errors
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.ERROR)
log.addHandler(console_handler)

# Suppress unnecessary warnings
logging.getLogger('urllib3').setLevel(logging.ERROR)
logging.getLogger('requests').setLevel(logging.ERROR)

app = Flask(__name__)

app.config['UPLOAD_FOLDER'] = 'image'

# Configurations
CONFIG_FILE = 'config.yaml'
LOG_FILE = 'snakemake_execution.log'
PID_FILE = 'snakemake.pid'

# Global variables for browse
browse_result = None
browse_event = threading.Event()

# Execution status
execution_status = {
    'running': False,
    'pid': None,
    'start_time': None,
    'end_time': None,
    'status': 'idle',  # idle, running, completed, failed, stopped
    'message': '',
    'progress': 0,
    'total_jobs': 0,
    'completed_jobs': 0
}

# Logo configuration
LOGO_PATHS = [
    os.path.join('static', 'image', 'logo.png'),
    os.path.join('image', 'logo.png'),
    os.path.join('static', 'logo.png')
]

# Find the logo
LOGO_PATH = None
for path in LOGO_PATHS:
    if os.path.exists(path):
        LOGO_PATH = path
        break

def load_config():
    """Load the YAML configuration file"""
    try:
        with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
            config = yaml.safe_load(f)
        return config
    except FileNotFoundError:
        return get_default_config()
    except Exception as e:
        print(f"Error loading config: {e}")
        return get_default_config()

def save_config(config):
    """Save the YAML configuration file"""
    try:
        with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
            yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
        return True
    except Exception as e:
        print(f"Error saving config: {e}")
        return False

def get_default_config():
    """Returns default configuration with EggNOG and PGAP added"""
    return {
        'paths': {
            'fasta_dir': '/path/to/your/genomes',
            'output_dir': '/path/to/your/output'
        },
        'general': {
            'threads': 8
        },
        'resources': {
            'mem_mb': 16000,
            'max_jobs': 2
        },
        'bakta': {
            'enabled': True,
            'docker_image': 'engbio/bakta:v1',
            'db_path': '/path/to/bakta_db',
            'db_type': 'light',
            'genus': 'Streptomyces',
            'species': '',
            'strain': '',
            'gram': '+',
            'translation_table': 11,
            'min_contig_length': 200,
            'compliant': False
        },
        'prokka': {
            'enabled': True,
            'docker_image': 'engbio/prokka:v1',
            'genus': 'Streptomyces',
            'kingdom': 'Bacteria',
            'gcode': 11
        },
        'dfast': {
            'enabled': True,
            'docker_image': 'engbio/dfast:v1',
            'db_path': '/path/to/dfast_db',
            'organism': 'Streptomyces'
        },
        'patric': {
            'enabled': True,
            'docker_image': 'engbio/patric:v1',
            'username': 'user@bv-brc.org',
            'password': 'your_password',
            'taxonomy_id': 1883,
            'description': 'Bacteria',
            'workspace_output_dir': 'home',
            'monitor_interval': 60
        },
        'eggnog': {
            'enabled': True,
            'docker_image': 'quay.io/biocontainers/eggnog-mapper:2.1.13--pyhdfd78af_1',
            'db_path': '/path/to/eggnog_data',
            'sensmode': 'diamond'
        },
        'pgap': {
            'enabled': True,
            'script_path': 'pgap.py',
            'mem': '24g',
            'cpus': 8,
            'extra_args': '--ignore-all-errors',
            'species': 'Streptomyces iranensis'
        },
        'merge': {
            'docker_image': 'engbio/merge:v1',
            'min_pident': 95.0,
            'min_qcov': 0.9,
            'jobs': 2
        }
    }

def get_snakemake_version():
    """Get the snakemake version"""
    try:
        result = subprocess.run(['snakemake', '--version'], 
                               capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except:
        pass
    return None

def get_system_info():
    """Obtain system information to configure features"""
    try:
        cpu_count = psutil.cpu_count(logical=True)
        mem = psutil.virtual_memory()
        mem_gb = mem.total / (1024**3)
        
        return {
            'cpu_count': cpu_count,
            'mem_total_gb': round(mem_gb, 1),
            'mem_available_gb': round(mem.available / (1024**3), 1),
            'recommended_threads': min(cpu_count, 16),
            'recommended_mem': min(int(mem.available / (1024**2)), 32000)
        }
    except:
        return {
            'cpu_count': 8,
            'mem_total_gb': 16,
            'mem_available_gb': 8,
            'recommended_threads': 8,
            'recommended_mem': 16000
        }

def check_snakemake_installed():
    """Check if snakemake is installed"""
    try:
        result = subprocess.run(['snakemake', '--version'], 
                               capture_output=True, text=True)
        return result.returncode == 0, result.stdout.strip()
    except:
        return False, None

def check_docker_installed():
    """Check if Docker is installed"""
    try:
        result = subprocess.run(['docker', '--version'], 
                               capture_output=True, text=True)
        return result.returncode == 0, result.stdout.strip()
    except:
        return False, None

def build_snakemake_command(config):
    cmd = ['snakemake']
    
    # Config file
    cmd.extend(['--configfile', CONFIG_FILE])
    
    # Threads
    threads = config.get('general', {}).get('threads', 16)
    cmd.extend(['--cores', str(threads)])
        
    # Max jobs from config
    max_jobs = config.get('resources', {}).get('max_jobs', 2)
    cmd.extend(['--jobs', str(max_jobs)])
    
    # Memory (pode usar o valor do config também)
    mem_mb = config.get('resources', {}).get('mem_mb', 16000)
    cmd.extend(['--resources', f'mem_mb={mem_mb}', '--keep-going','--rerun-incomplete'])
    
    print(f" Command: {' '.join(cmd)}")
    print(f" Threads: {threads}, Jobs: {max_jobs}, Memory: {mem_mb}MB")
    
    return cmd

def update_progress_from_line(line):
    """Updates progress based on each line of the log in real time"""
    global execution_status
    
    try:
        line_lower = line.lower().strip()
        
        # ===== TOTAL JOBS DETECTION =====
        if execution_status['total_jobs'] == 0:
            # Look for "Job stats:" or "job counts"
            if 'job stats' in line_lower or 'job counts' in line_lower:
                numbers = re.findall(r'\b(\d+)\b', line)
                if numbers:
                    # Take the largest number as total (usually the last)
                    execution_status['total_jobs'] = max(int(n) for n in numbers)
                    print(f"Total jobs detected: {execution_status['total_jobs']}")
            
            # Try to extract from lines like "rule_name: 5" (accumulate)
            if ':' in line and any(c.isdigit() for c in line):
                parts = line.split(':')
                if len(parts) == 2 and parts[1].strip().isdigit():
                    if not hasattr(update_progress_from_line, 'job_counts'):
                        update_progress_from_line.job_counts = []
                    count = int(parts[1].strip())
                    update_progress_from_line.job_counts.append(count)
                    if len(update_progress_from_line.job_counts) > 1:
                        execution_status['total_jobs'] = sum(update_progress_from_line.job_counts)
                
        # Format with timestamp and jobid
        match = re.search(r'finished jobid:\s*(\d+)', line_lower)
        if match:
            job_id = int(match.group(1))
            execution_status['completed_jobs'] = max(execution_status['completed_jobs'], job_id + 1)
            update_progress_percent()
        
        # ===== FORMAT: "Finished job 0." or "Finished rule 1." =====
        match = re.search(r'finished (?:job|rule)\s*(\d+)', line_lower)
        if match:
            job_num = int(match.group(1))
            execution_status['completed_jobs'] = max(execution_status['completed_jobs'], job_num + 1)
            update_progress_percent()
        
        # ===== SPECIFIC FORMAT: "1 of 10 steps (10%) done" =====
        match = re.search(r'(\d+)\s+of\s+(\d+)\s+(?:steps|jobs).*?(\d+)%.*?done', line_lower)
        if match:
            current = int(match.group(1))
            total = int(match.group(2))
            percent = int(match.group(3))
            execution_status['completed_jobs'] = current
            execution_status['total_jobs'] = total
            execution_status['progress'] = percent
            print(f"Progress: {percent}% ({current}/{total}) - {line.strip()}")
        
        # ===== ALTERNATIVE FORMAT: "x% done" =====
        match = re.search(r'(\d+)%\s+done', line_lower)
        if match:
            percent = int(match.group(1))
            execution_status['progress'] = percent
        
        # ===== FORMAT: "progress: X%" =====
        match = re.search(r'progress:?\s*(\d+)%', line_lower)
        if match:
            execution_status['progress'] = min(int(match.group(1)), 99)
        
        # ===== FORMAT: "[X/Y]" =====
        match = re.search(r'\[(\d+)/(\d+)\]', line_lower)
        if match:
            current = int(match.group(1))
            total = int(match.group(2))
            execution_status['completed_jobs'] = current
            execution_status['total_jobs'] = total
            progress = (current / total) * 100
            execution_status['progress'] = min(int(progress), 99)
        
        # ===== DETECT RULE START FOR MESSAGE =====
        if 'rule' in line_lower and ':' in line_lower and 'applying' not in line_lower:
            match = re.search(r'rule\s+(\w+)', line_lower)
            if match:
                execution_status['message'] = f"Running rule: {match.group(1)}"
        
        # ===== DETECT COMPLETION =====
        if 'complete log' in line_lower or 'all rules completed' in line_lower:
            execution_status['progress'] = 100
            execution_status['message'] = 'Workflow completed!'
        
        # ===== DETECT ERRORS =====
        if 'error' in line_lower and 'exception' not in line_lower:
            execution_status['message'] = f"Error: {line.strip()}"
            
    except Exception as e:
        print(f"Error updating progress from line: {e}")

def update_progress_percent():
    """Auxiliary function for calculating percentage progress"""
    global execution_status
    
    if execution_status['total_jobs'] > 0:
        progress = (execution_status['completed_jobs'] / execution_status['total_jobs']) * 100
        execution_status['progress'] = min(int(progress), 99)

def monitor_log_file():
    """Monitor the log file in real time (tail -f) as a fallback"""
    global execution_status
    
    if not os.path.exists(LOG_FILE):
        return
    
    try:
        with open(LOG_FILE, 'r', encoding='utf-8') as f:
            # Go to the end of the file
            f.seek(0, 2)
            
            while execution_status['running']:
                line = f.readline()
                if line:
                    update_progress_from_line(line)
                else:
                    time.sleep(0.1)
    except Exception as e:
        print(f"Error monitoring log: {e}")

def run_snakemake_command():
    """Run snakemake command locally in a separate thread - IMPROVED VERSION"""
    global execution_status
    
    try:
        # Load current configuration
        config = load_config()
        
        # Build command
        cmd = build_snakemake_command(config)
        
        print(f"Command to execute: {' '.join(cmd)}")
        
        execution_status['running'] = True
        execution_status['status'] = 'running'
        execution_status['message'] = 'Starting local execution...'
        execution_status['start_time'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        execution_status['progress'] = 0
        execution_status['total_jobs'] = 0
        execution_status['completed_jobs'] = 0
        
        # Open log file
        with open(LOG_FILE, 'w', encoding='utf-8') as log:
            log.write(f"=== Execution started on {execution_status['start_time']} ===\n")
            log.write(f"Command: {' '.join(cmd)}\n")
            log.write(f"Working directory: {os.getcwd()}\n")
            log.write(f"Snakemake version: {get_snakemake_version()}\n")
            log.write("="*80 + "\n\n")
            log.flush()
            
            # Start process with PIPE to read in real time
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,  # Line buffered
                universal_newlines=True
            )
        
        execution_status['pid'] = process.pid
        
        # Save PID to file
        with open(PID_FILE, 'w') as f:
            f.write(str(process.pid))
        
        # Start log monitoring thread as fallback
        monitor_thread = threading.Thread(target=monitor_log_file)
        monitor_thread.daemon = True
        monitor_thread.start()
        
        # Read output line by line in real time
        while True:
            # Read a line from the process output
            line = process.stdout.readline()
            
            if line:
                # Write to log file
                with open(LOG_FILE, 'a', encoding='utf-8') as log:
                    log.write(line)
                    log.flush()
                
                # UPDATE PROGRESS IN REAL TIME - LINE BY LINE
                update_progress_from_line(line)
                
                # Debug log for important lines
                if any(keyword in line.lower() for keyword in ['finished', 'rule', 'job', 'done', '%']):
                    print(f"Progress: {execution_status['progress']}% - {line.strip()[:100]}")
            else:
                # No new line, check if process finished
                return_code = process.poll()
                if return_code is not None:
                    # Read remaining output
                    remaining_output, _ = process.communicate()
                    if remaining_output:
                        with open(LOG_FILE, 'a', encoding='utf-8') as log:
                            log.write(remaining_output)
                            log.flush()
                        # Process remaining lines
                        for line in remaining_output.splitlines():
                            update_progress_from_line(line)
                    break
            
            # Small pause to not overload CPU
            time.sleep(0.05)
        
        return_code = process.returncode
        
        # Process finished
        if return_code == 0:
            execution_status['status'] = 'completed'
            execution_status['message'] = 'Execution completed successfully!'
            execution_status['progress'] = 100
        else:
            execution_status['status'] = 'failed'
            execution_status['message'] = f'Execution failed with code {return_code}'
            
        # Add information to log
        with open(LOG_FILE, 'a', encoding='utf-8') as log:
            log.write(f"\n{'='*80}\n")
            log.write(f"Execution completed with code: {return_code}\n")
            log.write(f"Status: {execution_status['status']}\n")
            
    except Exception as e:
        execution_status['status'] = 'failed'
        execution_status['message'] = f'Error: {str(e)}'
        print(f"Error in execution: {e}")
        
        try:
            with open(LOG_FILE, 'a', encoding='utf-8') as log:
                log.write(f"\n{'='*80}\n")
                log.write(f"ERROR: {str(e)}\n")
        except:
            pass
    finally:
        execution_status['running'] = False
        execution_status['end_time'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        
        if os.path.exists(PID_FILE):
            try:
                os.remove(PID_FILE)
            except:
                pass

def update_progress_from_log():
    """Update progress based on log lines (fallback)"""
    global execution_status
    
    try:
        if os.path.exists(LOG_FILE):
            with open(LOG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            # Look for total jobs
            job_stats_match = re.search(r'Job stats:.*?\n((?:\s+\w+\s+\d+\n?)+)', content, re.DOTALL)
            if job_stats_match and execution_status['total_jobs'] == 0:
                jobs_text = job_stats_match.group(1)
                job_lines = re.findall(r'\s+(\w+)\s+(\d+)', jobs_text)
                if job_lines:
                    total = sum(int(count) for _, count in job_lines)
                    execution_status['total_jobs'] = total
                    print(f"Total jobs detected (fallback): {total}")
            
            # Look for completed jobs
            finished_matches = re.findall(r'Finished (?:job|rule) (\d+)\.', content)
            if finished_matches:
                execution_status['completed_jobs'] = len(set(finished_matches))
            
            # Calculate progress
            if execution_status['total_jobs'] > 0:
                progress = (execution_status['completed_jobs'] / execution_status['total_jobs']) * 100
                execution_status['progress'] = min(int(progress), 99)
                    
    except Exception as e:
        print(f"Error updating progress (fallback): {e}")

def check_existing_process():
    """Check if there is a snakemake process running"""
    global execution_status
    
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, 'r') as f:
                pid = int(f.read().strip())
            
            try:
                os.kill(pid, 0)
                process = psutil.Process(pid)
                cmdline = ' '.join(process.cmdline())
                if 'snakemake' in cmdline:
                    execution_status['running'] = True
                    execution_status['status'] = 'running'
                    execution_status['pid'] = pid
                    return True
                else:
                    os.remove(PID_FILE)
            except (psutil.NoSuchProcess, OSError):
                os.remove(PID_FILE)
        except Exception as e:
            print(f"Error checking process: {e}")
            if os.path.exists(PID_FILE):
                try:
                    os.remove(PID_FILE)
                except:
                    pass
    
    return False

# Browse functions
def _open_directory_dialog(initial_dir):
    """Internal function to open directory dialog (fallback)"""
    global browse_result, browse_event
    
    try:
        root = tk.Tk()
        root.withdraw()
        root.attributes('-topmost', True)
        
        # ===== IMPROVEMENTS =====
        # Set DPI scaling (2.0 = 200% scale) – adjust as needed
        root.tk.call('tk', 'scaling', 2.5)
        
        # Set a larger geometry for the hidden root window
        root.geometry('1024x768')
        root.update()
        
        # Increase default font size globally (affects any Tk widgets)
        import tkinter.font as tkFont
        default_font = tkFont.nametofont("TkDefaultFont")
        default_font.configure(size=14)
        # ========================
        
        selected_dir = filedialog.askdirectory(
            title="Select Directory",
            initialdir=initial_dir if os.path.exists(initial_dir) else '/'
        )
        
        root.destroy()
        browse_result = selected_dir if selected_dir else None
        
    except Exception as e:
        print(f"Error in directory dialog: {e}")
        browse_result = None
    finally:
        browse_event.set()

def ensure_tkinter():
    """Check if tkinter is available"""
    try:
        import tkinter
        return True
    except ImportError:
        print("Tkinter is not installed. Installing...")
        try:
            subprocess.run(['sudo', 'apt-get', 'install', '-y', 'python3-tk'], check=True)
            import tkinter
            return True
        except:
            print("Could not install tkinter.")
            return False

# Application routes
@app.route('/logo')
def serve_logo():
    """Unified route to serve the logo"""
    if LOGO_PATH and os.path.exists(LOGO_PATH):
        return send_file(LOGO_PATH)
    else:
        return '', 404

@app.route('/image/<path:filename>')
def serve_image(filename):
    """Serve images from image folder"""
    return send_from_directory('image', filename)

@app.route('/static/image/<path:filename>')
def serve_static_image(filename):
    """Serve images from static/image folder"""
    return send_from_directory('static/image', filename)

@app.route('/')
def index():
    """Main page"""
    return render_template('index.html')

# Route to create directory
@app.route('/api/create/directory', methods=['POST'])
def create_directory():
    """Create a new directory"""
    try:
        data = request.json
        parent_path = data.get('parent_path', '/home')
        dir_name = data.get('dir_name', 'results')
        
        # Remove trailing slashes and normalize path
        parent_path = os.path.normpath(parent_path)
        
        # Full path
        full_path = os.path.join(parent_path, dir_name)
        
        # Check if it already exists
        if os.path.exists(full_path):
            return jsonify({
                'success': False,
                'message': f'Directory already exists: {full_path}'
            }), 400
        
        # Create the directory
        os.makedirs(full_path, exist_ok=True)
        
        return jsonify({
            'success': True,
            'path': full_path,
            'full_path': full_path,
            'message': f'Directory created successfully'
        })
        
    except PermissionError:
        return jsonify({
            'success': False,
            'message': 'Permission denied. Cannot create directory.'
        }), 403
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500

@app.route('/api/browse/directory', methods=['POST'])
def browse_directory():
    """Open dialog to select directory (fallback, kept for compatibility)"""
    global browse_result, browse_event
    
    try:
        data = request.json
        current_path = data.get('current_path', '/')
        
        browse_event.clear()
        browse_result = None
        
        thread = threading.Thread(target=_open_directory_dialog, args=(current_path,))
        thread.daemon = True
        thread.start()
        
        if browse_event.wait(timeout=60):
            if browse_result:
                return jsonify({
                    'success': True,
                    'path': browse_result,
                    'message': 'Directory selected'
                })
            else:
                return jsonify({
                    'success': False,
                    'cancelled': True,
                    'message': 'Selection cancelled'
                })
        else:
            return jsonify({
                'success': False,
                'message': 'Timeout waiting for selection'
            }), 408
            
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

# ===== NEW WEB-BASED DIRECTORY BROWSER =====
@app.route('/browse')
def browse_page():
    """Serve the web directory browser."""
    field = request.args.get('field', '')
    return render_template('dir_browser.html', field=field)

@app.route('/api/browse/web', methods=['POST'])
def browse_directory_web():
    """Return a list of subdirectories for the given path."""
    data = request.json
    current_path = data.get('path', '/')
    current_path = os.path.abspath(current_path)

    try:
        items = os.listdir(current_path)
        dirs = []
        for item in items:
            full_path = os.path.join(current_path, item)
            if os.path.isdir(full_path):
                dirs.append({'name': item, 'path': full_path})
        dirs.sort(key=lambda x: x['name'].lower())
        return jsonify({
            'success': True,
            'current_path': current_path,
            'parent_path': os.path.dirname(current_path) if current_path != '/' else None,
            'directories': dirs
        })
    except PermissionError:
        return jsonify({'success': False, 'message': 'Permission denied'}), 403
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/browse/select', methods=['POST'])
def select_directory():
    """(Optional) endpoint to confirm selection."""
    data = request.json
    selected_path = data.get('selected_path')
    field = data.get('field', '')
    if selected_path:
        return jsonify({'success': True, 'selected': selected_path, 'field': field})
    return jsonify({'success': False, 'message': 'No path provided'}), 400

# ===== END NEW ROUTES =====

@app.route('/api/config', methods=['GET'])
def get_config():
    """Return current configuration"""
    config = load_config()
    return jsonify(config)

@app.route('/api/config', methods=['POST'])
def update_config():
    """Update configuration"""
    try:
        new_config = request.json
        if save_config(new_config):
            return jsonify({'success': True, 'message': 'Configuration saved successfully!'})
        else:
            return jsonify({'success': False, 'message': 'Error saving configuration'}), 500
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/execute', methods=['POST'])
def execute_snakemake():
    """Start local snakemake execution"""
    global execution_status
    
    if execution_status['running']:
        return jsonify({'success': False, 'message': 'There is already an execution in progress.'}), 400
    
    if check_existing_process():
        return jsonify({'success': False, 'message': 'There is a snakemake process running'}), 400
    
    installed, version = check_snakemake_installed()
    if not installed:
        return jsonify({'success': False, 'message': 'Snakemake not found. Install with: conda install -c bioconda snakemake'}), 500
    
    docker_ok, docker_version = check_docker_installed()
    if not docker_ok:
        return jsonify({'success': False, 'warning': 'Docker not found. Annotator images may not work.'}), 200
    
    execution_status['running'] = True
    execution_status['progress'] = 0
    execution_status['total_jobs'] = 0
    execution_status['completed_jobs'] = 0
    
    thread = threading.Thread(target=run_snakemake_command)
    thread.daemon = True
    thread.start()
    
    return jsonify({
        'success': True, 
        'message': 'Local execution started',
        'snakemake_version': version,
        'docker_version': docker_version if docker_ok else None
    })

@app.route('/api/status', methods=['GET'])
def get_status():
    """Return execution status"""
    global execution_status
    
    if not execution_status['running']:
        check_existing_process()
    
    status = execution_status.copy()
    status['system'] = get_system_info()
    status['snakemake_version'] = get_snakemake_version()
    
    return jsonify(status)

@app.route('/api/stop', methods=['POST'])
def stop_execution():
    """Stop current execution"""
    global execution_status
    
    if execution_status['pid']:
        try:
            process = psutil.Process(execution_status['pid'])
            
            for child in process.children(recursive=True):
                try:
                    child.terminate()
                except:
                    pass
            
            process.terminate()
            
            time.sleep(2)
            
            if process.is_running():
                for child in process.children(recursive=True):
                    try:
                        child.kill()
                    except:
                        pass
                process.kill()
            
            execution_status['status'] = 'stopped'
            execution_status['message'] = 'Execution interrupted by the user'
            execution_status['running'] = False
            execution_status['end_time'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            
            with open(LOG_FILE, 'a', encoding='utf-8') as log:
                log.write(f"\n{'='*80}\n")
                log.write(f"Execution interrupted by the user in {execution_status['end_time']}\n")
            
            return jsonify({'success': True, 'message': 'Execution interrupted'})
            
        except Exception as e:
            return jsonify({'success': False, 'message': f'Error when stopping execution: {str(e)}'}), 500
    else:
        return jsonify({'success': False, 'message': 'No execution in progress'}), 400

# NEW ROUTE: Application shutdown
@app.route('/api/shutdown', methods=['POST'])
def shutdown_server():
    """Completely terminate the application and all related processes"""
    global execution_status
    
    try:
        print("\n" + "="*60)
        print("STARTING COMPLETE SHUTDOWN")
        print("="*60)
        
        # ===== 1. FIRST, TRY GENTLE STOP =====
        if execution_status['running'] and execution_status['pid']:
            try:
                print(f"Terminating Snakemake process (PID: {execution_status['pid']})...")
                
                # Try SIGTERM first (gentler)
                try:
                    os.kill(execution_status['pid'], signal.SIGTERM)
                    print("    SIGTERM sent")
                    time.sleep(3)  # Give time for graceful termination
                except:
                    pass
                
                # Check if still running
                try:
                    process = psutil.Process(execution_status['pid'])
                    if process.is_running():
                        print("    Process still running, sending SIGKILL...")
                        
                        # Kill all children recursively
                        children = process.children(recursive=True)
                        for child in children:
                            try:
                                print(f"    Killing child PID: {child.pid}")
                                child.kill()
                            except:
                                pass
                        
                        # Kill main process
                        process.kill()
                        print("    SIGKILL sent")
                except psutil.NoSuchProcess:
                    print("    Process already finished")
                    
            except Exception as e:
                print(f"   Error killing Snakemake: {e}")
        
        # ===== 2. KILL ALL SNAKEMAKE PROCESSES (FORCED) =====
        try:
            print("\nChecking for residual Snakemake processes...")
            
            # Use pkill to kill everything related to snakemake
            os.system("pkill -f snakemake")
            print("   • pkill snakemake executed")
            
            # Small pause
            time.sleep(1)
            
            # Check if any processes still exist
            result = subprocess.run(['pgrep', '-f', 'snakemake'], 
                                   capture_output=True, text=True)
            
            if result.stdout.strip():
                pids = result.stdout.strip().split('\n')
                print(f"   • {len(pids)} processes still running, killing one by one...")
                
                for pid in pids:
                    try:
                        os.kill(int(pid), signal.SIGKILL)
                        print(f"   • Killed PID: {pid}")
                    except:
                        pass
            else:
                print("   • No residual processes found")
                
        except Exception as e:
            print(f"    Error killing residual processes: {e}")
        
        # ===== 3. KILL DOCKER PROCESSES =====
        try:
            print("\nChecking Docker containers...")
            
            # List all related containers
            containers = [
                'snakemake', 'bakta', 'prokka', 'dfast', 
                'patric', 'eggnog', 'merge', 'pgap'
            ]
            
            for container_name in containers:
                try:
                    # Stop running containers
                    subprocess.run(
                        ['docker', 'stop', f'$(docker ps -q --filter name={container_name})'],
                        shell=True,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL
                    )
                    
                    # Remove stopped containers
                    subprocess.run(
                        ['docker', 'rm', '-f', f'$(docker ps -aq --filter name={container_name})'],
                        shell=True,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL
                    )
                except:
                    pass
            
            print("   • Docker containers processed")
            
        except Exception as e:
            print(f"    Error processing Docker: {e}")
        
        # ===== 4. KILL SPECIFIC DOCKER PROCESSES =====
        try:
            # Kill any container running with specific images
            images = [
                'engbio/bakta', 'engbio/prokka', 'engbio/dfast',
                'engbio/patric', 'engbio/eggnog', 'engbio/merge',
                'quay.io/biocontainers/eggnog-mapper', 'ncbi/pgap'
            ]
            
            for image in images:
                try:
                    # Find containers running with this image
                    result = subprocess.run(
                        ['docker', 'ps', '-q', '--filter', f'ancestor={image}'],
                        capture_output=True, text=True
                    )
                    
                    if result.stdout.strip():
                        containers = result.stdout.strip().split('\n')
                        for container in containers:
                            if container:
                                print(f"   • Stopping container: {container[:12]}")
                                subprocess.run(['docker', 'stop', container], 
                                             stdout=subprocess.DEVNULL)
                                subprocess.run(['docker', 'rm', '-f', container], 
                                             stdout=subprocess.DEVNULL)
                except:
                    pass
                    
        except Exception as e:
            print(f"    Error processing specific containers: {e}")
        
        # ===== 5. CLEAN FILES =====
        try:
            # Remove PID file if it exists
            if os.path.exists(PID_FILE):
                os.remove(PID_FILE)
                print("\nPID file removed")
            
            # Add final message to log
            try:
                with open(LOG_FILE, 'a', encoding='utf-8') as log:
                    log.write(f"\n{'='*80}\n")
                    log.write(f"APPLICATION SHUTDOWN at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
                    log.write(f"{'='*80}\n")
                print("Log finalized")
            except:
                pass
            
        except Exception as e:
            print(f"    Error cleaning files: {e}")
        
        print("\n" + "="*60)
        print("SHUTDOWN COMPLETE - Finalizing server...")
        print("="*60)
        
        # ===== 6. FINALIZE FLASK SERVER =====
        def shutdown():
            time.sleep(2)  # Give time for response to be sent
            
            # Kill all Flask child processes
            try:
                current_pid = os.getpid()
                current_process = psutil.Process(current_pid)
                
                # Kill all children
                for child in current_process.children(recursive=True):
                    try:
                        child.terminate()
                    except:
                        pass
                
                time.sleep(0.5)
                
                # Kill any remaining threads
                for thread in threading.enumerate():
                    if thread != threading.main_thread():
                        print(f"   • Finalizing thread: {thread.name}")
                
            except:
                pass
            
            # Force exit
            os._exit(0)
        
        # Start shutdown thread
        threading.Thread(target=shutdown, daemon=True).start()
        
        return jsonify({
            'success': True, 
            'message': 'Server shutting down... All processes terminated.'
        })
        
    except Exception as e:
        print(f"CRITICAL SHUTDOWN ERROR: {e}")
        
        # Last resort - kill everything anyway
        try:
            os.system("pkill -9 -f snakemake")
            os.system("docker kill $(docker ps -q) 2>/dev/null")
            os.system("docker rm -f $(docker ps -aq) 2>/dev/null")
        except:
            pass
            
        return jsonify({'success': False, 'message': f'Error during shutdown: {str(e)}'}), 500
    
@app.route('/api/log', methods=['GET'])
def get_log():
    """Returns the log content"""
    try:
        if os.path.exists(LOG_FILE):
            with open(LOG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
                lines = f.readlines()
                last_lines = lines[-1000:] if len(lines) > 1000 else lines
                return jsonify({
                    'log': ''.join(last_lines),
                    'size': os.path.getsize(LOG_FILE),
                    'lines': len(lines)
                })
        else:
            return jsonify({'log': 'Log file not found', 'size': 0, 'lines': 0})
    except Exception as e:
        return jsonify({'log': f'Error reading log: {str(e)}', 'size': 0, 'lines': 0})

@app.route('/api/download/log', methods=['GET'])
def download_log():
    """Download the complete log file"""
    if os.path.exists(LOG_FILE):
        return send_file(
            LOG_FILE, 
            as_attachment=True, 
            download_name=f'snakemake_log_{datetime.now().strftime("%Y%m%d_%H%M%S")}.log',
            mimetype='text/plain'
        )
    else:
        return jsonify({'error': 'Log not found'}), 404

@app.route('/api/check', methods=['GET'])
def check_requirements():
    """Check the system requirements"""
    snakemake_ok, snakemake_version = check_snakemake_installed()
    docker_ok, docker_version = check_docker_installed()
    system_info = get_system_info()
    
    config = load_config()
    fasta_dir = config.get('paths', {}).get('fasta_dir', '')
    output_dir = config.get('paths', {}).get('output_dir', '')
    
    fasta_dir_exists = os.path.exists(fasta_dir) if fasta_dir else False
    output_dir_exists = os.path.exists(output_dir) if output_dir else False
    
    return jsonify({
        'snakemake': {
            'installed': snakemake_ok,
            'version': snakemake_version
        },
        'docker': {
            'installed': docker_ok,
            'version': docker_version
        },
        'system': system_info,
        'directories': {
            'fasta_dir': fasta_dir,
            'fasta_dir_exists': fasta_dir_exists,
            'output_dir': output_dir,
            'output_dir_exists': output_dir_exists,
            'current_dir': os.getcwd(),
            'config_file_exists': os.path.exists(CONFIG_FILE)
        }
    })

@app.route('/api/clear_log', methods=['POST'])
def clear_log():
    """Delete the log file in the application directory"""
    try:
        log_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "snakemake_execution.log")
        
        print(f" Trying to erase: {log_file}")
        
        if os.path.exists(log_file):
            os.remove(log_file)
            print(f" Deleted file: {log_file}")
            
            with open(log_file, 'w', encoding='utf-8') as f:
                f.write(f"=== Clean log in {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ===\n")
            
            return jsonify({'success': True, 'message': 'Log successfully deleted!'})
        else:
            with open(log_file, 'w', encoding='utf-8') as f:
                f.write(f"=== Log created on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ===\n")
            
            return jsonify({'success': True, 'message': 'Log file created (did not exist).'})
            
    except Exception as e:
        print(f" Error deleting log: {e}")
        return jsonify({'success': False, 'message': f'Error: {str(e)}'}), 500

@app.route('/api/version', methods=['GET'])
def get_version_info():
    """Returns version information"""
    return jsonify({
        'snakemake': get_snakemake_version(),
        'python': os.sys.version,
        'psutil': psutil.__version__
    })

if __name__ == '__main__':
    try:
        import psutil
    except ImportError:
        print("Installing psutil...")
        subprocess.run(['pip', 'install', 'psutil'])
        import psutil
    
    ensure_tkinter()
    check_existing_process()
    
    # Clear screen for cleaner presentation
    os.system('clear' if os.name == 'posix' else 'cls')
    
    print("\n" + "="*60)
    print("SnakeMergeAnnotation - Web Interface")
    print("="*60)
    
    snakemake_ok, snakemake_version = check_snakemake_installed()
    docker_ok, docker_version = check_docker_installed()
    system_info = get_system_info()
    
    print("\nSystem:")
    print(f"   • CPUs: {system_info['cpu_count']}")
    print(f"   • Total Memory: {system_info['mem_total_gb']} GB")
    print(f"   • Available Memory: {system_info['mem_available_gb']} GB")
    
    print("\nDependencies:")
    print(f"   • Snakemake: {'OK' if snakemake_ok else 'ERROR'} {snakemake_version if snakemake_ok else 'not found'}")
    print(f"   • Docker: {'OK' if docker_ok else 'ERROR'} {docker_version if docker_ok else 'not found'}")
    print(f"   • Tkinter: {'OK' if ensure_tkinter() else 'ERROR'}")
    
    print("\nDirectories:")
    print(f"   • Config: {CONFIG_FILE} {'OK' if os.path.exists(CONFIG_FILE) else 'ERROR'}")
    print(f"   • Working: {os.getcwd()}")
    
    print("\nServer URLs:")
    print(f"   • Local: http://localhost:5000")
    try:
        hostname = os.popen('hostname -I 2>/dev/null').read().strip().split()
        if hostname:
            print(f"   • Network: http://{hostname[0]}:5000")
    except:
        pass
    
    print("\n" + "="*60)
    print("Server is running! Press Ctrl+C to stop.")
    print("="*60 + "\n")
    
    # Configure error handling to show only critical errors
    import traceback
    
    def show_error(exc_type, exc_value, exc_traceback):
        if issubclass(exc_type, KeyboardInterrupt):
            sys.__excepthook__(exc_type, exc_value, exc_traceback)
            return
        print(f"\nERROR: {exc_value}")
    
    sys.excepthook = show_error
    
    # Start server with silent logs
    try:
        app.run(
            debug=False,  # Disable debug to avoid extra logs
            host='0.0.0.0', 
            port=5000, 
            threaded=True,
            use_reloader=False  # Avoid reloader logs
        )
    except Exception as e:
        print(f"\nFailed to start server: {e}")