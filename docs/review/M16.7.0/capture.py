import subprocess,time,sys
from pathlib import Path
import argparse
parser=argparse.ArgumentParser(description="Capture isolated Soniquill DEBUG fixtures without live providers.")
parser.add_argument("device")
parser.add_argument("group", choices=["iphone", "small", "ipad"])
parser.add_argument("--app", default="/tmp/Soniquill-Rename-ios/Build/Products/Debug-iphonesimulator/Soniquill.app")
options=parser.parse_args()
udid,group=options.device,options.group
root=Path(__file__).parent/group
root.mkdir(parents=True,exist_ok=True)
app=options.app
def run(*args):subprocess.run(['xcrun','simctl',*args],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['xcrun','simctl','boot',udid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
run('bootstatus',udid,'-b')
run('install',udid,app)
data=Path(subprocess.check_output(['xcrun','simctl','get_app_container',udid,'cz.kudladev.soniquill','data'],text=True).strip())
fixture=data/'tmp/AudioNotes-M11-Fixtures'
run('status_bar',udid,'override','--time','9:41','--batteryState','charged','--batteryLevel','100')
base=['--performance-fixtures','--ios-audio-review','--ios-ux-review']
captures=[('library-light','light','large',base),('library-dark','dark','large',base),('recording-dark','dark','large',base+['--ios-review-detail']),('settings-light','light','large',base+['--ios-review-settings']),('settings-accessibility','light','accessibility-extra-extra-large',base+['--ios-review-settings']),('project-light','light','large',['--performance-fixtures','--ios-project-knowledge-review']),('project-chat-dark','dark','large',['--performance-fixtures','--ios-project-knowledge-review','--ios-project-review-chat'])]
for name,theme,size,args in captures:
 run('ui',udid,'appearance',theme);run('ui',udid,'content_size',size)
 marker=fixture/('ios-project-knowledge-review-ready' if '--ios-project-knowledge-review' in args else 'ios-ux-review-ready')
 marker.unlink(missing_ok=True)
 run('launch','--terminate-running-process',udid,'cz.kudladev.soniquill',*args)
 deadline=time.monotonic()+45
 while not marker.exists() and time.monotonic()<deadline:time.sleep(.5)
 if not marker.exists():raise SystemExit('Fixture did not become ready: '+name)
 time.sleep(8)
 run('io',udid,'screenshot',str(root/(name+'.png')))
run('ui',udid,'content_size','large');run('ui',udid,'appearance','light')
run('terminate',udid,'cz.kudladev.soniquill')
