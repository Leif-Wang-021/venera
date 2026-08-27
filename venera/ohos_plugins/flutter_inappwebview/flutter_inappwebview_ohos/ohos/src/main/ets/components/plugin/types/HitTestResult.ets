/*
* Copyright (c) 2024 Hunan OpenValley Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import web_webview from '@ohos.web.webview'
import { Any } from '@ohos/flutter_ohos'

export default class HitTestResult {
  private type: number
  private extra: string | null

  constructor(type: number, extra: string | null) {
    this.type = type
    this.extra = extra
  }

  public static fromWebViewHitTestResult(hitTestResult: web_webview.HitTestValue | null): HitTestResult | null {
    if (hitTestResult == null) {
      return null;
    }
    return new HitTestResult(hitTestResult.type, hitTestResult.extra);
  }

  public getType(): number {
    return this.type;
  }

  public setType(type: number): void {
    this.type = type;
  }

  public getExtra(): string | null {
    return this.extra;
  }

  public setExtra(extra: string | null): void {
    this.extra = extra;
  }

  public toMap(): Map<string, Any> {
    let hitTestResultMap: Map<string, Any> = new Map<string, Any>()
    hitTestResultMap.set("type", this.type);
    hitTestResultMap.set("extra", this.extra);
    return hitTestResultMap;
  }

  public equals(o: Any): boolean {
    if (this == o) return true;
    // if (o == null || getClass() != o.getClass()) return false;

    let that: HitTestResult = o as HitTestResult;

    if (this.type != that.type) return false;
    return this.extra != null ? this.extra.includes(that.extra??'') : that.extra == null;
  }

  public hashCode(): number {
    let result: number = this.type;
    // result = 31 * result + (this.extra != null ? this.extra.hashCode() : 0);
    return result;
  }

  public toString(): string {
    return "HitTestResultMap{" +
      "type=" + this.type +
      ", extra='" + this.extra + '\'' +
      '}';
  }
}