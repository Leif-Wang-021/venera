import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { displaySync } from '@kit.ArkGraphics2D';
import { AbilityConstant, Want } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import VeneraFilePickerPlugin from '../plugins/VeneraFilePickerPlugin';

export default class EntryAbility extends FlutterAbility {
  private static displaySync_?: displaySync.DisplaySync = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam);
    this.startHighRefreshRate();
  }

  onDestroy(): void {
    EntryAbility.stopHighRefreshRate();
    super.onDestroy();
  }

  private startHighRefreshRate(): void {
    try {
      const ds: displaySync.DisplaySync = displaySync.create();
      ds.setExpectedFrameRateRange({
        expected: 120,
        min: 90,
        max: 120
      });
      ds.on('frame', () => {
        // Continuous high-rate UI draw requests keep the LTPO screen at the
        // desired refresh while the app renders (comic reading / scrolling).
      });
      ds.start();
      EntryAbility.displaySync_ = ds;
    } catch (e) {
      console.error(`startHighRefreshRate failed: ${JSON.stringify(e as BusinessError)}`);
    }
  }

  private static stopHighRefreshRate(): void {
    try {
      EntryAbility.displaySync_?.stop();
      EntryAbility.displaySync_ = undefined;
    } catch (e) {
      console.error(`stopHighRefreshRate failed: ${JSON.stringify(e as BusinessError)}`);
    }
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // Native Pickers (system file manager) for open/save/folder flows.
    flutterEngine.getPlugins()?.add(new VeneraFilePickerPlugin())
  }
}