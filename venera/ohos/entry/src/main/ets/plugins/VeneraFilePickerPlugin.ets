// Venera OHOS system file manager (Picker) integration.
// Channel: venera/ohos_file
//   openDocument(exts: string[], mime: string) -> { path }
//   pickDirectory()                       -> { path }
//   saveDocument(filename, dataBase64)    -> { saved }
import AbilityAware from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityAware';
import { AbilityPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityPluginBinding';
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodChannel from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fileUri as fileUriModule } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';

const TAG = 'VeneraFilePicker';
const CHANNEL_NAME = 'venera/ohos_file';

export default class VeneraFilePickerPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private abilityBinding: AbilityPluginBinding | null = null;

  getUniqueClassName(): string {
    return 'VeneraFilePickerPlugin';
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityBinding = binding;
    this.channel?.setMethodCallHandler(this);
  }

  onDetachedFromAbility(): void {
    this.abilityBinding = null;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    Log.i(TAG, 'onAttachedToEngine');
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  private getContext(): common.UIAbilityContext {
    if (this.abilityBinding) {
      return this.abilityBinding.getAbility().context;
    }
    throw new Error('no ability binding');
  }

  private bundleName(): string {
    try {
      let ctx = this.getContext();
      let b = ctx.abilityInfo?.bundleName as string;
      if (b && b.length > 0) {
        return b;
      }
    } catch (e) {
      Log.e(TAG, 'bundleName fallback: ' + JSON.stringify(e));
    }
    return 'com.github.wgh136.venera';
  }

  private appDownloadDir(): string {
    return `/storage/Users/currentUser/Download/${this.bundleName()}`;
  }

  private ensureDir(path: string): boolean {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path);
      }
      return true;
    } catch (e) {
      Log.e(TAG, 'ensureDir failed ' + path + ': ' + JSON.stringify(e));
      return false;
    }
  }

  private async uriToPath(uri: string): Promise<string | null> {
    try {
      let fu = new fileUriModule.FileUri(uri);
      return fu.path;
    } catch (e) {
      Log.e(TAG, 'uriToPath failed: ' + JSON.stringify(e));
      return null;
    }
  }

  private sanitize(name: string): string {
    let out = name.replace(/[\\/:*?"<>|\s]/g, '_');
    return out.length > 0 ? out : 'file';
  }

  private async openDocument(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let exts: string[] = (call.argument('exts') as string[]) || [];
      let ctx = this.getContext();
      let documentPicker = new picker.DocumentViewPicker(ctx);
      let options = new picker.DocumentSelectOptions();
      if (exts.length > 0) {
        options.fileSuffixFilters = [exts.map((e) => '.' + e.replace(/^\./, '')).join(',')];
      }
      let uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        result.success({ path: null });
        return;
      }
      let src = uris[0];
      let path = await this.uriToPath(src);
      let copyTo = this.getContext().cacheDir;
      this.ensureDir(copyTo);
      let fileName = 'file';
      let fu2 = new fileUriModule.FileUri(src);
      fileName = fu2.name || 'file';
      let dest = `${copyTo}/${this.sanitize(fileName)}`;
      let srcFile = fs.openSync(src, fs.OpenMode.READ_ONLY);
      let dstFile = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      let bufSize = Math.min(4 * 1024 * 1024, 4 * 1024 * 1024);
      let buffer = new ArrayBuffer(bufSize);
      let bytesRead = fs.readSync(srcFile.fd, buffer);
      while (bytesRead > 0) {
        fs.writeSync(dstFile.fd, buffer.slice(0, bytesRead));
        bytesRead = fs.readSync(srcFile.fd, buffer);
      }
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
      Log.i(TAG, 'openDocument copied to ' + dest + ' (uri ' + src + ', path ' + path + ')');
      result.success({ path: dest });
    } catch (e) {
      Log.e(TAG, 'openDocument failed: ' + JSON.stringify(e));
      let err = e as BusinessError;
      result.error('openDocument', err.message ?? JSON.stringify(e), null);
    }
  }

  private async pickDirectory(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let ctx = this.getContext();
      let documentPicker = new picker.DocumentViewPicker(ctx);
      let options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      let uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        result.success({ path: null });
        return;
      }
      let picked = await this.uriToPath(uris[0]);
      let usable: string | null = null;
      if (picked) {
        // Only paths that dart:io can actually open are useful: the app
        // sandbox (/data/storage/...) or the app's own public Download
        // sub-directory. Other user-folder URIs are not addressable from
        // dart:io, so we must map the choice back to an app-owned dir.
        let p = picked;
        if ((p.startsWith('/data/storage/') || p.startsWith('/storage/Users/currentUser/Download/')) && this.ensureDir(p)) {
          try {
            let probe = `${p}/.venera_probe`;
            let pf = fs.openSync(probe, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(pf.fd, new ArrayBuffer(0));
            fs.closeSync(pf);
            fs.unlinkSync(probe);
            usable = p;
          } catch (e) {
            Log.w(TAG, 'picked dir not writable, fallback: ' + JSON.stringify(e));
          }
        } else {
          Log.w(TAG, 'picked dir not dart:io-usable: ' + p);
        }
      }
      if (usable === null) {
        // Fallback 1: the app's own public Download dir (visible in the
        // system Files app). Fallback 2: the app sandbox base dir, which is
        // guaranteed to be reachable from dart:io.
        let dl = this.appDownloadDir();
        if (this.ensureDir(dl)) {
          let comics = `${dl}/local_comics`;
          if (this.ensureDir(comics)) {
            usable = comics;
          }
        }
      }
      if (usable === null) {
        let sd = `${ctx.filesDir}/venera_storage`;
        if (this.ensureDir(sd)) {
          usable = sd;
        }
      }
      Log.i(TAG, 'pickDirectory resolves to ' + usable);
      result.success({ path: usable });
    } catch (e) {
      Log.e(TAG, 'pickDirectory failed: ' + JSON.stringify(e));
      let err = e as BusinessError;
      result.error('pickDirectory', err.message ?? JSON.stringify(e), null);
    }
  }

  private async saveDocument(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let filename: string = (call.argument('filename') as string) || 'file';
      let dataBase64: string = (call.argument('dataBase64') as string) || '';
      let ctx = this.getContext();
      let documentPicker = new picker.DocumentViewPicker(ctx);
      let options = new picker.DocumentSaveOptions();
      options.newFileNames = [this.sanitize(filename)];
      let uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        result.success({ saved: false });
        return;
      }
      let dst = uris[0];
      let base64 = new util.Base64Helper();
      let decoded = base64.decodeSync(dataBase64);
      // decodeSync returns Uint8Array; fs.writeSync needs an ArrayBuffer.
      let bytes = decoded.buffer.slice(decoded.byteOffset, decoded.byteOffset + decoded.byteLength);
      let f = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      let written = fs.writeSync(f.fd, bytes);
      fs.closeSync(f);
      Log.i(TAG, 'saveDocument wrote ' + filename + ' bytes=' + written);
      result.success({ saved: true });
    } catch (e) {
      Log.e(TAG, 'saveDocument failed: ' + JSON.stringify(e));
      let err = e as BusinessError;
      result.error('saveDocument', err.message ?? JSON.stringify(e), null);
    }
  }

  private async saveFileFromPath(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let filename: string = (call.argument('filename') as string) || 'file';
      let srcPath: string = (call.argument('srcPath') as string) || '';
      let ctx = this.getContext();
      let documentPicker = new picker.DocumentViewPicker(ctx);
      let options = new picker.DocumentSaveOptions();
      options.newFileNames = [this.sanitize(filename)];
      let uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        result.success({ saved: false });
        return;
      }
      let dst = uris[0];
      // Copy straight from the sandbox file to the user picked URI — no huge
      // base64 round-trip over the method channel.
      let srcFile = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      let dstFile = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      let bufSize = 4 * 1024 * 1024;
      let buffer = new ArrayBuffer(bufSize);
      let bytesRead = fs.readSync(srcFile.fd, buffer);
      while (bytesRead > 0) {
        fs.writeSync(dstFile.fd, buffer.slice(0, bytesRead));
        bytesRead = fs.readSync(srcFile.fd, buffer);
      }
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
      Log.i(TAG, 'saveFileFromPath wrote ' + filename);
      result.success({ saved: true });
    } catch (e) {
      Log.e(TAG, 'saveFileFromPath failed: ' + JSON.stringify(e));
      let err = e as BusinessError;
      result.error('saveFileFromPath', err.message ?? JSON.stringify(e), null);
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    Log.d(TAG, 'onMethodCall ' + call.method);
    switch (call.method) {
      case 'openDocument':
        this.openDocument(call, result);
        break;
      case 'pickDirectory':
        this.pickDirectory(call, result);
        break;
      case 'saveDocument':
        this.saveDocument(call, result);
        break;
      case 'saveFileFromPath':
        this.saveFileFromPath(call, result);
        break;
      default:
        result.notImplemented();
    }
  }
}