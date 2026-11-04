#!/usr/bin/env python3
"""Dispatch at most twice, retrying only a hosted runner acquisition failure."""
import argparse
import json
import re
import subprocess
import sys

REPO = 'PastFly/Selective-Remote'
ACQUISITION = 'The job was not acquired by Runner of type hosted even after multiple attempts'


def run(args, check=True):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


def api(path):
    return json.loads(run(['gh', 'api', path]).stdout)


def acquisition_only(failed_jobs):
    return bool(failed_jobs) and all(not job['steps'] and ACQUISITION in job['annotations'] for job in failed_jobs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ref', required=True, help='Exact test branch name')
    parser.add_argument('--workflow', default='test-dmg.yml')
    parser.add_argument('--build', help='Optional workflow build input')
    args = parser.parse_args()
    expected = api('repos/' + REPO + '/git/ref/heads/' + args.ref)['object']['sha']
    for attempt in range(1, 3):
        cmd = ['gh', 'workflow', 'run', args.workflow, '--repo', REPO, '--ref', args.ref]
        if args.build:
            cmd += ['-f', 'build=' + args.build]
        result = run(cmd)
        match = re.search(r'https://github\.com/PastFly/Selective-Remote/actions/runs/(\d+)', result.stdout)
        if not match:
            raise SystemExit('Could not identify dispatched run; no retry performed')
        run_id = match.group(1)
        print(json.dumps({'attempt': attempt, 'run_id': run_id, 'expected_harness_sha': expected}), flush=True)
        watch = subprocess.run(['gh', 'run', 'watch', run_id, '--repo', REPO, '--interval', '20', '--exit-status'])
        info = api('repos/' + REPO + '/actions/runs/' + run_id)
        if info['head_sha'] != expected or info['status'] != 'completed':
            raise SystemExit('Run SHA changed or completion not verified; no retry performed')
        if watch.returncode == 0 and info['conclusion'] == 'success':
            print(json.dumps({'run_id': run_id, 'conclusion': 'success'})); return
        jobs = api('repos/' + REPO + '/actions/runs/' + run_id + '/jobs?per_page=100')['jobs']
        failed = []
        for job in jobs:
            if job['conclusion'] in ('failure', 'cancelled', 'timed_out'):
                annotations = api('repos/' + REPO + '/check-runs/' + str(job['id']) + '/annotations')
                failed.append({'steps': job['steps'], 'annotations': '\n'.join(x['message'] for x in annotations)})
        if not acquisition_only(failed):
            raise SystemExit('Test or other failure; no automatic retry performed')
        if attempt == 2:
            raise SystemExit('Hosted runner acquisition failed twice; bounded retries exhausted')
        print('Hosted runner acquisition failed; making one final attempt.', flush=True)


if __name__ == '__main__':
    main()
