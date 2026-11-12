import 'dart:math' as math;
import 'dart:typed_data';

/// 频谱分离：用「重复背景估计」(REPET 思路) 把人声从伴奏里抠出来
/// 原理：伴奏通常是重复的（同样的和弦、鼓点一遍遍循环），
/// 人声在时间轴上几乎不重复。于是在每个频点上取一段时间的中位数当"背景"，
/// 超出背景的那部分能量就是人声，再逆变换回去。
class Spectral {
  static Float32List _hann(int n) {
    final w = Float32List(n);
    for (int i = 0; i < n; i++) {
      w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
    }
    return w;
  }

  static List<int> _bitRev(int n) {
    final bits = math.log(n) ~/ math.ln2;
    final rev = List<int>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      int r = 0;
      int v = i;
      for (int b = 0; b < bits; b++) {
        r = (r << 1) | (v & 1);
        v >>= 1;
      }
      rev[i] = r;
    }
    return rev;
  }

  static void _fft(Float32List re, Float32List im, List<int> rev, List<double> cosT, List<double> sinT) {
    final n = re.length;
    for (int i = 0; i < n; i++) {
      final j = rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (int size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (int i = 0; i < n; i += size) {
        for (int j = 0; j < half; j++) {
          final k = j * step;
          final wr = cosT[k];
          final wi = -sinT[k];
          final idx = i + j + half;
          final xr = re[idx] * wr - im[idx] * wi;
          final xi = re[idx] * wi + im[idx] * wr;
          re[idx] = re[i + j] - xr;
          im[idx] = im[i + j] - xi;
          re[i + j] += xr;
          im[i + j] += xi;
        }
      }
    }
  }

  /// 输入单声道 PCM，返回"人声"单声道 PCM（长度与输入相同）
  static Float32List vocals(
    Float32List x, {
    int n = 2048,
    int hop = 1024,
    int half = 8,
  }) {
    final len = x.length;
    if (len < n) return Float32List.fromList(x);

    final frames = ((len - n) ~/ hop) + 1;
    final bins = n ~/ 2 + 1;
    final win = _hann(n);
    final rev = _bitRev(n);
    final cosT = List<double>.generate(n ~/ 2, (i) => math.cos(2 * math.pi * i / n));
    final sinT = List<double>.generate(n ~/ 2, (i) => math.sin(2 * math.pi * i / n));

    // 一遍：算出幅度谱
    final mags = Float32List(frames * bins);
    final re = Float32List(n);
    final im = Float32List(n);
    for (int f = 0; f < frames; f++) {
      final off = f * hop;
      for (int i = 0; i < n; i++) {
        re[i] = x[off + i] * win[i];
        im[i] = 0;
      }
      _fft(re, im, rev, cosT, sinT);
      final base = f * bins;
      for (int b = 0; b < bins; b++) {
        mags[base + b] = math.sqrt(re[b] * re[b] + im[b] * im[b]);
      }
    }

    // 背景：每个频点沿时间取中位数
    final bg = Float32List(frames * bins);
    final buf = Float32List(2 * half + 1);
    for (int b = 0; b < bins; b++) {
      for (int f = 0; f < frames; f++) {
        int cnt = 0;
        for (int k = f - half; k <= f + half; k++) {
          final kk = k < 0 ? 0 : (k >= frames ? frames - 1 : k);
          buf[cnt++] = mags[kk * bins + b];
        }
        // 插入排序取中位（窗口很小，够快）
        for (int i = 1; i < cnt; i++) {
          final v = buf[i];
          int j = i - 1;
          while (j >= 0 && buf[j] > v) {
            buf[j + 1] = buf[j];
            j--;
          }
          buf[j + 1] = v;
        }
        bg[f * bins + b] = buf[cnt ~/ 2];
      }
    }

    // 二遍：软掩码 + 逆变换重叠相加
    final out = Float32List(len);
    final inv = Float32List(len);
    final re2 = Float32List(n);
    final im2 = Float32List(n);
    for (int f = 0; f < frames; f++) {
      final off = f * hop;
      for (int i = 0; i < n; i++) {
        re2[i] = x[off + i] * win[i];
        im2[i] = 0;
      }
      _fft(re2, im2, rev, cosT, sinT);
      final base = f * bins;
      for (int b = 0; b < bins; b++) {
        final m = mags[base + b];
        final g = bg[base + b];
        if (m <= 1e-9) continue;
        var mask = (m - g) / m;
        if (mask < 0) mask = 0;
        if (mask > 1) mask = 1;
        // 稍微压一点，减少人声轨里的音乐残留
        mask = math.pow(mask, 1.2).toDouble();
        re2[b] *= mask;
        if (b > 0 && b < bins - 1) {
          // 镜像频点也要按同样掩码处理
          final nb = n - b;
          final m2 = math.sqrt(re2[nb] * re2[nb] + im2[nb] * im2[nb]);
          if (m2 > 1e-9) {
            re2[nb] *= mask;
            im2[nb] *= mask;
          }
        }
      }
      // 逆 FFT：取共轭后正变换，再除以 n
      for (int i = 0; i < n; i++) {
        im2[i] = -im2[i];
      }
      _fft(re2, im2, rev, cosT, sinT);
      for (int i = 0; i < n; i++) {
        final s = re2[i] / n;
        out[off + i] += s * win[i];
        inv[off + i] += win[i] * win[i];
      }
    }
    for (int i = 0; i < len; i++) {
      if (inv[i] > 1e-6) out[i] /= inv[i];
    }
    return out;
  }
}
