import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';

/**
 * 她的「眼睛」：智谱图片理解。
 *
 * 只做一件事 —— 把手机里的一张图片，换成一段客观的画面描述文字。
 * 描述随后交给 DeepSeek，由她按自己的人设、记忆、语气接着聊。
 * 所以这里刻意不让智谱扮演角色、不写人设 prompt：它只是字典，不是她。
 *
 *   POST https://open.bigmodel.cn/api/paas/v4/chat/completions
 *   Authorization: Bearer <智谱 Key>
 *   content: [ {type:image_url,...data:image/jpeg;base64...}, {type:text,...} ]
 *
 * 模型选 glm-4.6v-flash：这个 Key 上 glm-4v-flash / glm-4v-plus / glm-4.6v 都报
 * 「余额不足或无可用资源包」（错误码 1113），glm-4.1v-thinking-flash 会带一大段
 * <think>；只有 glm-4.6v-flash 可用且输出干净。
 *
 * 免费额度的代价是**会排队**：同一张图连打 6 次，2 次直接成功、4 次回 429 +
 * 错误码 1305「该模型当前访问量过大」。这不是 Key 问题也不是额度问题，等一两秒
 * 重试就能挤进去，所以下面做了 3 次尝试（1.2s / 2.6s 退避）。
 * 只有 1113 才是真的没额度，那种情况重试没用，直接告诉用户去充值。
 */

const API_URL: string = 'https://open.bigmodel.cn/api/paas/v4/chat/completions';
const MODEL: string = 'glm-4.6v-flash';
/** 长边上限：手机随手拍 4000px 太浪费，1024 足够看清主体，base64 也小一个数量级 */
const MAX_EDGE: number = 1024;
/** JPEG 质量：文字/线条截图也够清楚 */
const JPEG_QUALITY: number = 80;
/** 免费池排队（可重试） */
const CODE_BUSY: string = '1305';
/** 余额不足 / 没有资源包（重试没用） */
const CODE_NO_QUOTA: string = '1113';
/** 最多试几次（含首次） */
const MAX_ATTEMPTS: number = 3;

// ArkTS 严格模式：所有对象字面量都要有显式声明的类型
interface ImageUrlDetail {
  url: string;
}

interface ContentPart {
  type: string;
  image_url?: ImageUrlDetail;
  text?: string;
}

interface ReqMessage {
  role: string;
  content: ContentPart[];
}

interface ChatRequestBody {
  model: string;
  messages: ReqMessage[];
  max_tokens: number;
  temperature: number;
}

interface RespMessage {
  content?: string;
  reasoning_content?: string;
}

interface Choice {
  message?: RespMessage;
}

interface RespError {
  code?: string;
  message?: string;
}

interface ChatResp {
  choices?: Choice[];
  error?: RespError;
}

/** 退避等待 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 把本地图片压到长边 <= MAX_EDGE 的 JPEG，再编码成 base64 字符串 */
async function toBase64(path: string): Promise<string> {
  const src: image.ImageSource = image.createImageSource(path);
  let pixel: image.PixelMap | undefined = undefined;
  let packer: image.ImagePacker | undefined = undefined;
  try {
    const info: image.ImageInfo = await src.getImageInfo();
    const w: number = info.size.width;
    const h: number = info.size.height;
    const scale: number = Math.min(MAX_EDGE / w, MAX_EDGE / h, 1);
    const tw: number = Math.max(1, Math.round(w * scale));
    const th: number = Math.max(1, Math.round(h * scale));
    const decodeOpts: image.DecodingOptions = { desiredSize: { width: tw, height: th } };
    pixel = await src.createPixelMap(decodeOpts);
    packer = image.createImagePacker();
    const packing: image.PackingOption = { format: 'image/jpeg', quality: JPEG_QUALITY };
    const buf: ArrayBuffer = await packer.packToData(pixel, packing);
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(new Uint8Array(buf));
  } finally {
    if (packer !== undefined) {
      packer.release();
    }
    if (pixel !== undefined) {
      pixel.release();
    }
    src.release();
  }
}

/** 从响应体里挖智谱的错误码；不是 JSON 就返回空串 */
function errCodeOf(raw: string): string {
  try {
    const data: ChatResp = JSON.parse(raw) as ChatResp;
    if (data.error !== undefined && data.error.code !== undefined) {
      return data.error.code;
    }
  } catch (e) {
    // 非 JSON（网关错误页之类），交给调用方当普通失败处理
  }
  return '';
}

/**
 * 解析 200 响应里的描述。空内容不在这里抛错 —— 免费模型偶尔把 max_tokens
 * 耗在思考上，外层会重试一次再说。
 */
function parseDescription(raw: string): string {
  let data: ChatResp;
  try {
    data = JSON.parse(raw) as ChatResp;
  } catch (e) {
    throw new Error('图片识别返回了看不懂的内容（不是 JSON）');
  }
  if (data.error !== undefined && data.error.message !== undefined) {
    throw new Error('图片识别失败：' + data.error.message);
  }
  if (data.choices === undefined || data.choices.length === 0
    || data.choices[0].message === undefined
    || data.choices[0].message!.content === undefined) {
    return '';
  }
  let desc: string = data.choices[0].message!.content!.trim();
  // thinking 模型偶尔带 <think>…</think>，描述里绝不能混进这种内部痕迹
  const close: number = desc.indexOf('</think>');
  if (desc.startsWith('<think>') && close > 0) {
    desc = desc.substring(close + '</think>'.length).trim();
  }
  // 她说的每句话都会过 Markdown，尖括号留着会被当成标签吃掉
  desc = desc.replace(/</g, '＜').replace(/>/g, '＞');
  return desc;
}

export class VisionService {
  /**
   * 识别一张本地图片，返回客观中文描述（约 100 字）。
   * Key 为空直接报错，不静默降级成「看不到图片」—— 那会让她又装瞎。
   */
  static async describe(path: string, apiKey: string): Promise<string> {
    if (apiKey.trim().length === 0) {
      throw new Error('没填图片识别 Key（设置里的「图片识别 Key」），看图功能用不了');
    }
    const b64: string = await toBase64(path);
    const imgUrl: ImageUrlDetail = { url: 'data:image/jpeg;base64,' + b64 };
    const imgPart: ContentPart = { type: 'image_url', image_url: imgUrl };
    const textPart: ContentPart = {
      type: 'text',
      text: '客观描述这张图片：画了什么、主体外观和颜色、表情动作、背景与文字。'
        + '用中文，100 字以内，只描述画面，不要评价、不要猜拍摄者意图、不要说「这张图片显示」。'
    };
    const parts: ContentPart[] = [imgPart, textPart];
    const msg: ReqMessage = { role: 'user', content: parts };
    const msgs: ReqMessage[] = [msg];
    const body: ChatRequestBody = {
      model: MODEL,
      messages: msgs,
      // 免费 flash 偶尔先把 token 花在思考上，给足余量免得 content 空着回来
      max_tokens: 800,
      temperature: 0.3
    };
    const header: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + apiKey.trim()
    };
    const payload: string = JSON.stringify(body);

    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      if (attempt > 0) {
        await delay(attempt === 1 ? 1200 : 2600);
      }
      const req = http.createHttp();
      let resp: http.HttpResponse | undefined = undefined;
      try {
        resp = await req.request(API_URL, {
          method: http.RequestMethod.POST,
          header: header,
          extraData: payload,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 8000,
          readTimeout: 60000
        });
      } finally {
        req.destroy();
      }
      if (resp === undefined) {
        throw new Error('图片识别没有响应');
      }
      const raw: string = typeof resp.result === 'string' ? resp.result : String(resp.result);

      if (resp.responseCode === 200) {
        const desc: string = parseDescription(raw);
        if (desc.length > 0) {
          console.info('[VISION] 识别成功，模型 ' + MODEL + '，描述：' + desc);
          return desc;
        }
        // 200 但空内容：免费模型把 token 耗在思考上了，退避后再要一次
        console.warn('[VISION] 返回空描述，第 ' + (attempt + 1) + ' 次');
        continue;
      }

      if (resp.responseCode === 429) {
        const code: string = errCodeOf(raw);
        if (code === CODE_NO_QUOTA) {
          console.warn('[VISION] 智谱 1113：' + raw.substring(0, 200));
          throw new Error('这个 Key 的看图额度用完或没有资源包了（智谱 1113），'
            + '去 bigmodel.cn 充一点或换一个 Key');
        }
        // 1305（以及没带码的 429）都是免费池排队，等一两秒重试有用
        console.warn('[VISION] 智谱 429 '
          + (code.length > 0 ? code : '无码') + '，第 ' + (attempt + 1) + ' 次');
        continue;
      }

      if (resp.responseCode === 401) {
        console.warn('[VISION] 智谱 401：' + raw.substring(0, 200));
        throw new Error('图片识别 Key 不对（智谱返回 401）');
      }
      throw new Error('图片识别没成功（智谱返回 ' + resp.responseCode + '）');
    }

    throw new Error('看图模型正在排队（智谱 1305），稍等几秒再发一次');
  }
}
