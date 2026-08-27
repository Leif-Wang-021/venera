import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';

/**
 * 内置浏览器页面：随 url_launcher (harmony_browser_page) 拉起打开链接。
 */
@Entry
@Component
struct BrowserPage {
  @State url: string = '';
  controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    const param = router.getParams() as Record<string, string>;
    if (param && param['url']) {
      this.url = param['url'];
    }
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(14)
          .onClick(() => {
            router.back();
          })
        Blank()
        Text(this.url)
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ right: 12 })
      }
      .width('100%')
      .height(48)
      .padding({ left: 8 })

      if (this.url.length > 0) {
        Web({ src: this.url, controller: this.controller })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}