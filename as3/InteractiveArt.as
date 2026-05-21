/**
 * ==============================================================
 *  InteractiveArt.as  —  ActionScript 3.0
 *  インタラクティブアート — 画像差分法による動体検出
 *
 *  論文:「Webデザインの技術によるインタラクティブアートの可能性」
 *
 *  論文で使用されていた ActionScript の組み込み関数:
 *    ・Camera.getCamera()       — カメラ映像取得
 *    ・BitmapData.draw(video)   — フレームキャプチャ
 *    ・BitmapData.compare()     — フレーム間差分（論文の核心）
 *    ・BitmapData.getPixel32()  — ピクセル値読み取り
 *    ・Graphics.drawCircle()    — 円描画（Mode 0 / Mode 1）
 *    ・Graphics.curveTo()       — 曲線描画（Mode 2）
 *
 *  コンパイル方法（Apache Flex SDK）:
 *    mxmlc InteractiveArt.as -output InteractiveArt.swf
 *
 *  実行方法:
 *    Adobe Flash Player Standalone (Projector) で
 *    InteractiveArt.swf を開く
 *
 *  操作:
 *    M キー  — モード手動切替
 *    ↑ キー  — 閾値を上げる（感度を下げる）
 *    ↓ キー  — 閾値を下げる（感度を上げる）
 * ==============================================================
 */

package {

  import flash.display.Bitmap;
  import flash.display.BitmapData;
  import flash.display.Graphics;
  import flash.display.Sprite;
  import flash.display.StageAlign;
  import flash.display.StageScaleMode;
  import flash.events.Event;
  import flash.events.KeyboardEvent;
  import flash.events.SampleDataEvent;
  import flash.events.TimerEvent;
  import flash.geom.ColorTransform;
  import flash.geom.Matrix;
  import flash.geom.Point;
  import flash.geom.Rectangle;
  import flash.media.Camera;
  import flash.media.Sound;
  import flash.media.SoundChannel;
  import flash.media.Video;
  import flash.text.TextField;
  import flash.text.TextFieldAutoSize;
  import flash.text.TextFormat;
  import flash.utils.Timer;

  // SWF メタデータ（コンパイル時の出力設定）
  [SWF(width="1280", height="720", frameRate="30", backgroundColor="#000000")]

  public class InteractiveArt extends Sprite {

    // ----------------------------------------------------------------
    //  定数
    // ----------------------------------------------------------------
    private static const W:int            = 1280;    // 幅
    private static const H:int            = 720;     // 高さ
    private static const FPS:Number       = 30;      // フレームレート
    private static const STEP:int         = 6;       // グリッドサンプリング間隔 (px)
    private static const MODE_FRAMES:int  = 1800;    // 60秒 × 30fps でモード切替

    // ----------------------------------------------------------------
    //  カメラ・映像オブジェクト
    // ----------------------------------------------------------------
    private var _cam:Camera;   // ActionScript 3.0 カメラ API
    private var _vid:Video;    // カメラ映像を受け取る Video オブジェクト

    // ----------------------------------------------------------------
    //  ビットマップ
    // ----------------------------------------------------------------
    private var _prevBD:BitmapData;   // 前フレームのスナップショット
    private var _canvasBD:BitmapData; // 描画バッファ（フェード効果付き永続バッファ）
    private var _canvasDisp:Bitmap;   // 画面表示用 Bitmap

    // ----------------------------------------------------------------
    //  状態変数
    // ----------------------------------------------------------------
    private var _threshold:int  = 25;          // 差分閾値（大きいほど鈍感）
    private var _mode:int       = 0;           // 表示モード 0/1/2
    private var _frameNum:int   = 0;           // フレームカウンタ
    private var _mode1Color:uint;              // Mode 1 用固定カラー

    // ----------------------------------------------------------------
    //  フェード用 ColorTransform
    // ----------------------------------------------------------------
    private var _fadeCT:ColorTransform;        // RGB を 0.94 倍（徐々に暗くなる）
    private var _fullRect:Rectangle;           // キャンバス全体の Rectangle

    // ----------------------------------------------------------------
    //  音声（SampleDataEvent による正弦波生成）
    // ----------------------------------------------------------------
    private var _sound:Sound;
    private var _soundCh:SoundChannel;
    private var _soundFreq:Number   = 440;    // 現在の音高（Hz）
    private var _soundPhase:Number  = 0;      // 位相
    private var _soundActive:Boolean = false;
    private var _soundTimer:Timer;

    // ----------------------------------------------------------------
    //  UI
    // ----------------------------------------------------------------
    private var _statusTF:TextField;

    private static const MODE_NAMES:Array = [
      "Mode 0 — 円（ランダムサイズ・ランダムカラー）",
      "Mode 1 — 円（均一サイズ・単色）",
      "Mode 2 — ベジェ曲線（ランダム）"
    ];

    // ================================================================
    //  コンストラクタ
    // ================================================================
    public function InteractiveArt() {
      stage.scaleMode = StageScaleMode.NO_SCALE;
      stage.align     = StageAlign.TOP_LEFT;

      _initDisplay();
      _initCamera();
      _initAudio();
      _initUI();

      addEventListener(Event.ENTER_FRAME, _onFrame);
    }

    // ================================================================
    //  初期化 — 描画バッファ
    // ================================================================
    private function _initDisplay():void {
      // 永続描画バッファ（毎フレームクリアしない → 残像効果）
      _canvasBD   = new BitmapData(W, H, false, 0x000000);
      _canvasDisp = new Bitmap(_canvasBD);
      addChild(_canvasDisp);

      // ColorTransform: RGB を 0.94 倍 → 毎フレーム少しずつ暗くなる（残像フェード）
      _fadeCT   = new ColorTransform(0.94, 0.94, 0.94, 1.0, 0, 0, 0, 0);
      _fullRect = new Rectangle(0, 0, W, H);

      _mode1Color = uint(Math.random() * 0xFFFFFF);
    }

    // ================================================================
    //  初期化 — カメラ（論文の実装に対応する部分）
    // ================================================================
    private function _initCamera():void {
      // 論文と同様: ActionScript 組み込み関数 Camera.getCamera() でカメラを取得
      _cam = Camera.getCamera();

      if (_cam == null) {
        trace("[InteractiveArt] ERROR: カメラが見つかりません。");
        trace("  → Flash Player の設定でカメラアクセスを許可してください。");
        return;
      }

      trace("[InteractiveArt] カメラ取得成功: " + _cam.name);

      // 解像度とフレームレートを設定
      _cam.setMode(W, H, FPS);

      // 品質設定（帯域幅=0: 無制限, 品質=90%）
      _cam.setQuality(0, 90);

      // Video オブジェクトにカメラを接続
      // Video は Stage に addChild しない（差分計算の入力源としてのみ利用）
      _vid = new Video(W, H);
      _vid.attachCamera(_cam);

      // ※ addChild(_vid) するとカメラ映像がそのまま表示される
      //   論文の実装では表示せず、BitmapData.draw() の入力のみに使用
    }

    // ================================================================
    //  初期化 — 音声（SampleDataEvent による PCM 正弦波生成）
    //  Web Audio API の OscillatorNode に相当する ActionScript の手法
    // ================================================================
    private function _initAudio():void {
      _sound = new Sound();
      _sound.addEventListener(SampleDataEvent.SAMPLE_DATA, _onSample);

      // 一定時間後に音を停止するタイマー
      _soundTimer = new Timer(250, 1);
      _soundTimer.addEventListener(TimerEvent.TIMER_COMPLETE,
        function(e:TimerEvent):void {
          if (_soundCh) {
            _soundCh.stop();
            _soundActive = false;
          }
        }
      );
    }

    // 音声サンプルデータ生成（44100Hz, モノラル正弦波 → ステレオ出力）
    private function _onSample(e:SampleDataEvent):void {
      for (var i:int = 0; i < 2048; i++) {
        _soundPhase += _soundFreq / 44100.0;
        if (_soundPhase >= 1.0) _soundPhase -= 1.0;
        var s:Number = Math.sin(_soundPhase * Math.PI * 2.0) * 0.06;
        e.data.writeFloat(s); // L チャンネル
        e.data.writeFloat(s); // R チャンネル
      }
    }

    // 縦位置から周波数を決定して再生（上=高音、下=低音）
    private function _playNote(y:int):void {
      _soundFreq = 1200.0 - (Number(y) / Number(H)) * (1200.0 - 80.0);

      if (!_soundActive) {
        _soundCh    = _sound.play();
        _soundActive = true;
      }

      // 250ms で停止（新しい音が来るたびにリセット）
      _soundTimer.reset();
      _soundTimer.start();
    }

    // ================================================================
    //  初期化 — UI
    // ================================================================
    private function _initUI():void {
      _statusTF = new TextField();
      _statusTF.defaultTextFormat =
        new TextFormat("_typewriter", 11, 0x888888);
      _statusTF.autoSize         = TextFieldAutoSize.LEFT;
      _statusTF.selectable       = false;
      _statusTF.background       = true;
      _statusTF.backgroundColor  = 0x111111;
      _statusTF.x = 8;
      _statusTF.y = 8;
      addChild(_statusTF);

      // キーボードショートカット
      stage.addEventListener(KeyboardEvent.KEY_DOWN, _onKey);
    }

    private function _onKey(e:KeyboardEvent):void {
      switch (e.keyCode) {
        case 77:  // M → モード切替
          _mode = (_mode + 1) % 3;
          _mode1Color = uint(Math.random() * 0xFFFFFF);
          break;
        case 38:  // ↑ → 閾値+5（感度を下げる）
          _threshold = Math.min(100, _threshold + 5);
          break;
        case 40:  // ↓ → 閾値-5（感度を上げる）
          _threshold = Math.max(5, _threshold - 5);
          break;
      }
    }

    // ================================================================
    //  メインループ — ENTER_FRAME イベントで毎フレーム呼ばれる
    // ================================================================
    private function _onFrame(e:Event):void {
      _frameNum++;

      if (_cam == null || _vid == null) return;

      // 自動モード切替（MODE_FRAMES フレームごと）
      if (_frameNum > 0 && (_frameNum % MODE_FRAMES) === 0) {
        _mode = (_mode + 1) % 3;
        _mode1Color = uint(Math.random() * 0xFFFFFF);
        trace("[InteractiveArt] モード切替 → " + MODE_NAMES[_mode]);
      }

      // --------------------------------------------------------------
      //  Step 1: 現在フレームをキャプチャ（左右反転 = 鏡像）
      //
      //  BitmapData.draw(source, matrix) で Video を BitmapData に描画。
      //  Matrix(-1, 0, 0, 1, W, 0) は X 軸方向を反転する変換行列。
      //  → 参加者が自分の動きを鏡のように確認できる。
      // --------------------------------------------------------------
      var curBD:BitmapData = new BitmapData(W, H, false, 0x000000);
      curBD.draw(_vid, new Matrix(-1, 0, 0, 1, W, 0));

      if (_prevBD != null) {

        // ------------------------------------------------------------
        //  Step 2: BitmapData.compare() でフレーム間差分を取得
        //
        //  ★ これが論文で「ActionScriptの関数を使用」と記述されていた
        //    画像差分検出の核心部分。
        //
        //  compare() の戻り値:
        //    0          → 2フレームが完全に同一（動体なし）
        //   -3          → 幅が異なる（通常は発生しない）
        //   -4          → 高さが異なる（通常は発生しない）
        //   BitmapData  → 差分ビットマップ（各ピクセルが差分値）
        //
        //  差分ビットマップのピクセル形式（ARGB 32bit）:
        //    alpha=0x00 → 前後フレームで同一ピクセル（差異なし）
        //    alpha=0xFF → 差異あり
        //              R = |前フレームR - 現フレームR|
        //              G = |前フレームG - 現フレームG|
        //              B = |前フレームB - 現フレームB|
        // ------------------------------------------------------------
        var diffObj:Object = _prevBD.compare(curBD);

        if (diffObj is BitmapData) {
          var diffBD:BitmapData = BitmapData(diffObj);

          // ----------------------------------------------------------
          //  Step 3: 残像効果
          //  ColorTransform で描画バッファの RGB を 0.94 倍にする。
          //  → 過去に描いた図形が徐々に暗くなって消えていく。
          // ----------------------------------------------------------
          _canvasBD.colorTransform(_fullRect, _fadeCT);

          // ----------------------------------------------------------
          //  Step 4: 差分ビットマップを走査し、動体座標を抽出
          // ----------------------------------------------------------
          var motionPts:Vector.<Point> = _extractMotion(diffBD);
          diffBD.dispose(); // 差分ビットマップは使い終わったら解放

          // ----------------------------------------------------------
          //  Step 5: モードに応じた図形を動体座標に描画
          // ----------------------------------------------------------
          if (motionPts.length > 0) {
            _drawShapes(motionPts);

            // 動体検出時にランダムで音を鳴らす（縦位置 → 音高）
            if (Math.random() < 0.35) {
              var rp:Point = motionPts[int(Math.random() * motionPts.length)];
              _playNote(rp.y);
            }
          }

        }
        // diffObj === 0 の場合: フレームが完全に同一 → 何もしない

      }

      // --------------------------------------------------------------
      //  Step 6: 現フレームを「前フレーム」として保存
      //          次のループで compare() の第1引数になる
      // --------------------------------------------------------------
      if (_prevBD != null) _prevBD.dispose();
      _prevBD = curBD; // clone 不要（curBD をそのまま保持）

      // ステータス表示更新
      _statusTF.text =
        "[" + MODE_NAMES[_mode] + "]" +
        "  閾値: " + _threshold +
        "  |  M: モード切替  /  ↑↓: 感度調整";
    }

    // ================================================================
    //  差分ビットマップから動体座標を抽出
    // ================================================================
    private function _extractMotion(diffBD:BitmapData):Vector.<Point> {
      var pts:Vector.<Point> = new Vector.<Point>();

      // STEP px 間隔のグリッドでサンプリング
      // （全ピクセルを走査すると 1280×720 = 約92万回 → 重いためサブサンプリング）
      for (var y:int = 0; y < H; y += STEP) {
        for (var x:int = 0; x < W; x += STEP) {

          // compare() が返した差分ビットマップのピクセル値を読む
          var px:uint   = diffBD.getPixel32(x, y);
          var alpha:int = int((px >>> 24) & 0xFF);

          // alpha > 0 なら「差異あり」ピクセル
          if (alpha > 0) {
            var dr:int = int((px >>> 16) & 0xFF); // R チャンネルの差分
            var dg:int = int((px >>> 8)  & 0xFF); // G チャンネルの差分
            var db:int = int( px         & 0xFF); // B チャンネルの差分

            // RGB 平均差分が閾値を超えた座標のみ採用
            var avgDiff:int = (dr + dg + db) / 3;
            if (avgDiff > _threshold) {
              pts.push(new Point(x, y));
            }
          }
        }
      }

      return pts;
    }

    // ================================================================
    //  動体座標に図形を描画（3モード）
    // ================================================================
    private function _drawShapes(pts:Vector.<Point>):void {
      // 一時 Sprite に Graphics で描画 → BitmapData に焼き込む
      // （直接 canvasBD には描けないため、Sprite を中継する）
      var sp:Sprite  = new Sprite();
      var g:Graphics = sp.graphics;
      var pt:Point;

      switch (_mode) {

        // ------------------------------------------------------------
        //  Mode 0 — ランダムサイズ・ランダムカラーの円
        //  論文: 「カメラで撮影した映像と前フレームを比較して差があった
        //         座標にランダムなサイズで円が発生する」
        // ------------------------------------------------------------
        case 0:
          for each (pt in pts) {
            var r0:Number = 4 + Math.random() * 28;
            g.beginFill(uint(Math.random() * 0xFFFFFF), 0.8);
            g.drawCircle(
              pt.x + (Math.random() - 0.5) * 16,
              pt.y + (Math.random() - 0.5) * 16,
              r0
            );
            g.endFill();
          }
          break;

        // ------------------------------------------------------------
        //  Mode 1 — 均一サイズ・単色の円
        //  論文: 「均一なサイズで同じ色の円が発生する」
        // ------------------------------------------------------------
        case 1:
          g.beginFill(_mode1Color, 0.8);
          for each (pt in pts) {
            g.drawCircle(pt.x, pt.y, 10);
          }
          g.endFill();
          break;

        // ------------------------------------------------------------
        //  Mode 2 — ランダムなベジェ曲線
        //  論文: 「動体座標を起点にランダムな曲線が発生する」
        //  ActionScript の Graphics.curveTo() を使用（2次ベジェ曲線）
        // ------------------------------------------------------------
        case 2:
          for each (pt in pts) {
            var spread:Number = 80 + Math.random() * 40;
            g.lineStyle(2, uint(Math.random() * 0xFFFFFF), 0.8);
            g.moveTo(pt.x, pt.y);
            // curveTo(制御点X, 制御点Y, 終点X, 終点Y) — 2次ベジェ
            g.curveTo(
              pt.x + (Math.random() - 0.5) * spread,
              pt.y + (Math.random() - 0.5) * spread,
              pt.x + (Math.random() - 0.5) * spread * 1.5,
              pt.y + (Math.random() - 0.5) * spread * 1.5
            );
          }
          break;
      }

      // Sprite の内容を永続描画バッファに焼き込む
      // （ここで初めて画面に表示される内容が確定する）
      _canvasBD.draw(sp);
    }

  } // end class
} // end package
