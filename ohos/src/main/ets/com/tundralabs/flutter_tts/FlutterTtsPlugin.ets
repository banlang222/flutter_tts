import { FlutterPlugin, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HashMap } from '@kit.ArkTS';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

const TAG = 'FlutterTtsPlugin';
export default class FlutterTtsPlugin implements FlutterPlugin, MethodCallHandler {
  constructor() {
    console.debug(`new flutter tts plugin id=${Math.random()},${Math.random()}`);

  }

  private methodChannel:MethodChannel | null = null;
  private ttsEngine:textToSpeech.TextToSpeechEngine | null = null;
  private awaitSpeakCompletion:boolean = false;
  private awaitSynthCompletion:boolean = false;
  private speaking:boolean = false;
  private speakResult: MethodResult | null = null;
  private voices: textToSpeech.VoiceInfo[] = [];

  private engineExtraParams: Record<string, Object> = {
    "style": 'interaction-broadcast', //风格，当前仅支持
    "locate": "CN", //当前仅支持CN
    "name": "EngineName" //引擎名称
  };
  private engineParams: textToSpeech.CreateEngineParams = {
    language: 'zh-CN', //当前仅支持zh-CN
    person: 0, //音色，当前仅支持0=聆小珊
    online: 1, //当前仅支持1=离线
    extraParams: this.engineExtraParams
  };
  private speakExtraParams: Record<string, Object> = {
    "speed": 1, //0.5-2
    "volume": 1, //0-2
    "pitch": 1, //0.5-2
    "languageContext": "zh-CN", //当前仅支持
    "audioType": "pcm", //音频类型，pcm=脉冲编码调制
    "playType": 1, //0=仅合成不播报返回音频流 1=合成与播报不返回音频流
    "soundChannel": 3, //0-16, 3=语音播报 12=有声读物
    "queueMode": 0 //0=排队 1=抢占
  };

  private speakListener: textToSpeech.SpeakListener = {
    // 开始播报回调
    onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
      this.log(`requestId has started: ${requestId}`);
      this.invokeMethod('speak.onStart', true);
    },
    //合成完成及播报完成
    onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
      this.log(`speak: requestId(${requestId}) has completed ${response.type}, ${response.message}`);
      //response.type=1 播报结束
      if(response.type == 1) {
        if(this.awaitSpeakCompletion && this.speakExtraParams['queueMode'] == 0) {
          this.ttsEngine?.stop();
        }
        this.invokeMethod('speak.onComplete', true);
      }
    },
    //停止播报
    onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
      this.log(`speak: stop response = ${JSON.stringify(response)}`);
      if(this.awaitSpeakCompletion) {
        this.speaking = false;
      }
      this.speakCompletion(1);
      this.invokeMethod('speak.onCancel', true);
      this.log(`speak: stop requestId=${requestId}`);
    },
    //返回音频流，用于将音频流保存到文件，放弃
    onData(requestId: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse) {

    },
    onError: (requestId: string, errorCode: number, errorMessage: string): void => {
      this.log(`engine=${this.ttsEngine}}`);
      if(this.awaitSpeakCompletion) {
        this.speaking = false;
      }
      this.invokeMethod('speak.onError', `Error from textToSpeech (speak) - ${errorCode}`)

    }
  }

  private sentences:HashMap<string,string> = new HashMap();

  log(text:string) :void {
    console.debug(`${TAG}: ${text}`);
  }
  speakCompletion(success: number) {
    this.log('speak: completion send success');
    this.speaking = false;
    this.speakResult?.success(success);
    this.speakResult = null;
  }

  invokeMethod(method:string, args: ESObject):void {
    this.methodChannel?.invokeMethod(method, args);
  }

  getUniqueClassName(): string {
    return TAG;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.methodChannel = new MethodChannel(binding.getBinaryMessenger(), 'flutter_tts');
    this.methodChannel.setMethodCallHandler(this);
    textToSpeech.createEngine(this.engineParams, (err: BusinessError, textToSpeechEngine: textToSpeech.TextToSpeechEngine) => {
      if(!err) {
        this.log('tts engine created success');
        this.ttsEngine = textToSpeechEngine;
        this.ttsEngine.setListener(this.speakListener);
      } else {
        console.error(`tts engine created failed, code=${err.code}, message=${err.message}`);
      }
    });
  }


  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.methodChannel?.setMethodCallHandler(null);
    this.methodChannel = null;
    this.ttsEngine?.setListener(null);
    this.ttsEngine?.shutdown();
    this.ttsEngine = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.log(`incoming call : ${JSON.stringify(call)}`)
    if(call.method == 'speak') {
      let text:string = String(call.args);
      if(this.speaking && this.speakExtraParams['queueMode'] == 0) {
        this.log('queue mode and speaking now')
        result.success(0);
        return;
      }
      if(this.awaitSpeakCompletion && this.speakExtraParams['queueMode']==0) {
        if(this.ttsEngine?.isBusy()) {
          this.log('tts engine is busy');
        }
        this.log('wait completion');
        this.speaking = true;
        this.speakResult = result;
        this.speak(text);
      } else {
        this.speak(text);
        this.log('speak success');
        result.success(1);
      }
    } else if(call.method == 'awaitSpeakCompletion') {
      this.awaitSpeakCompletion = Boolean(call.args);
      result.success(1);
    } else if(call.method == 'awaitSynthCompletion') {
      this.awaitSynthCompletion = Boolean(call.args);
      result.success(1);
    } else if(call.method == 'getMaxSpeechInputLength') {
      result.success(10000);
    } else if(call.method == 'stop' || call.method == 'pause') {
      this.ttsEngine?.stop();
    } else if(call.method == 'setSpeechRate') {
      let rate:number | null = Number(call.args);
      if(!rate) {
        rate = 1;
      } else if(rate < 0.5){
        rate = 0.5;
      } else if(rate > 2) {
        rate = 2;
      } else {
        rate *= 2;
      }
      this.speakExtraParams['speed'] = rate;
      result.success(1);
    } else if(call.method == 'setVolume') {
      let volume:number | null = Number(call.args);
      if(!volume) {
        volume = 1;
      } else if(volume < 0) {
        volume = 0;
      } else if(volume > 2) {
        volume = 2;
      }
      this.speakExtraParams['volume'] = volume;
      result.success(1);
    } else if(call.method == 'setPitch') {
      let pitch: number | null = Number(call.args);
      if(!pitch) {
        pitch = 1;
      } else if(pitch < 0.5) {
        pitch = 0.5;
      } else if(pitch > 2) {
        pitch = 2;
      }
      this.speakExtraParams['pitch'] = pitch;
      result.success(1);
    } else if(call.method == 'getVoices') {
      if(this.voices.length == 0) {
        this.getVoices().then((value)=>{
          result.success(value);
        });
      }
    } else if(call.method == 'setQueueMode') {
      this.log(`new queue mode = ${call.args}`)
      let queue_mode: number = Number(call.args);
      if(queue_mode == 1) {
        this.speakExtraParams["queueMode"] = 1;
      } else {
        this.speakExtraParams["queueMode"] = 0;
      }
      result.success(1);
    }
    else {
      result.notImplemented();
    }
  }

  speak(text: string) : void {
  this.log('will speak');
    let id:string = this.randomId();
    this.sentences.set(id, text);
    this.log('sentences setted')
    let speakParams: textToSpeech.SpeakParams = {
      requestId: id,
      extraParams: this.speakExtraParams
    };
    this.ttsEngine?.speak(text, speakParams);
    this.log(`speak requestId=${id}, text=${text}}`);
  }

  randomId(): string {
    return `${Date.now()}${Math.random() * 1000}`;
  }

  async getVoices(): Promise<textToSpeech.VoiceInfo[]> {
    if(this.voices.length == 0) {
      let voicesQuery: textToSpeech.VoiceQuery = {
        requestId: this.randomId(),
        online: 1
      };
      let voiceInfo:textToSpeech.VoiceInfo[] | undefined = await this.ttsEngine?.listVoices(voicesQuery);
      if(voiceInfo) {
        this.voices = voiceInfo;
      } else {
        this.log('get voices err');
      }
    }
    return this.voices;
  }
}