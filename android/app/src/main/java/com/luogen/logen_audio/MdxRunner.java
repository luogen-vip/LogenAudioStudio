import ai.onnxruntime.*;
import org.jtransforms.fft.DoubleFFT_1D;
import java.io.*;
import java.nio.*;
import java.util.*;

/**
 * UVR MDX-Net 人声模型，手机端推理：
 * 44.1k 立体声 -> 峰值归一化 -> STFT(n_fft 7680, hop 1024, Hann) ->
 * 取前 3072 个频点、实部虚部分左右声道共 4 个平面 -> 256 帧一块 -> 模型 ->
 * 逆 STFT + 重叠相加 -> 人声；伴奏 = 原曲 - 人声。
 */
public class MdxRunner {
    static final int NFFT = 7680;
    static final int HOP = 1024;
    static final int DIMF = 3072;
    static final int FRAMES = 256;
    static final int PAD = NFFT / 2;

    public interface Progress { void onProgress(double p); }

    static double[] hann() {
        double[] w = new double[NFFT];
        for (int i = 0; i < NFFT; i++) w[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / NFFT);
        return w;
    }

    public static void main(String[] args) throws Exception {
        run(args[0], args[1], args[2], args[3], args.length > 4 ? Integer.parseInt(args[4]) : 0, p -> {
        });
    }

    public static void run(String modelPath, String mixPath, String vocalPath, String instPath,
                           int total, Progress cb) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(mixPath, "r");
        int avail = (int) (raf.length() / 8L);
        if (total <= 0 || total > avail) total = avail;

        float peak = 1e-6f;
        byte[] buf = new byte[1 << 16];
        raf.seek(0);
        int r;
        while ((r = raf.read(buf)) > 0) {
            ByteBuffer bb = ByteBuffer.wrap(buf, 0, r).order(ByteOrder.LITTLE_ENDIAN);
            for (int k = 0; k < r / 4; k++) {
                float v = bb.getFloat();
                if (Math.abs(v) > peak) peak = Math.abs(v);
            }
        }
        if (cb != null) cb.onProgress(0.02);

        OrtEnvironment env = OrtEnvironment.getEnvironment();
        OrtSession.SessionOptions so = new OrtSession.SessionOptions();
        so.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.BASIC_OPT);
        so.setIntraOpNumThreads(2);
        OrtSession sess = env.createSession(modelPath, so);
        if (cb != null) cb.onProgress(0.04);

        double[] win = hann();
        DoubleFFT_1D fft = new DoubleFFT_1D(NFFT);

        int nframes = (int) Math.ceil(total / (double) HOP) + 2;
        int chunks = (int) Math.ceil(nframes / (double) FRAMES);

        int BUF = NFFT + FRAMES * HOP + 2 * HOP;
        float[] accL = new float[BUF], accR = new float[BUF], ws = new float[BUF];
        int base = 0, flushed = 0;

        FloatBuffer tf = ByteBuffer.allocateDirect(4 * DIMF * FRAMES * 4)
                .order(ByteOrder.nativeOrder()).asFloatBuffer();
        byte[] fbytes = new byte[NFFT * 8];
        double[] d = new double[2 * NFFT];

        try (OutputStream vo = new BufferedOutputStream(new FileOutputStream(vocalPath), 1 << 16);
             OutputStream io = new BufferedOutputStream(new FileOutputStream(instPath), 1 << 16)) {
            for (int c = 0; c < chunks; c++) {
                int f0 = c * FRAMES;
                tf.clear();
                for (int fj = 0; fj < FRAMES; fj++) {
                    int fi = f0 + fj;
                    int start = fi * HOP - PAD;
                    Arrays.fill(fbytes, (byte) 0);
                    int from = Math.max(0, start);
                    int to = Math.min(total, start + NFFT);
                    if (to > from) {
                        raf.seek((long) from * 8L);
                        raf.readFully(fbytes, (from - start) * 8, (to - from) * 8);
                    }
                    for (int ch = 0; ch < 2; ch++) {
                        Arrays.fill(d, 0.0);
                        for (int k = 0; k < NFFT; k++) {
                            int p = start + k;
                            if (p < 0 || p >= total) continue;
                            int off = (p - from) * 8 + ch * 4;
                            int v = (fbytes[off] & 0xff) | ((fbytes[off + 1] & 0xff) << 8)
                                    | ((fbytes[off + 2] & 0xff) << 16) | ((fbytes[off + 3] & 0xff) << 24);
                            d[2 * k] = Float.intBitsToFloat(v) / peak * win[k];
                        }
                        fft.complexForward(d);
                        for (int b = 0; b < DIMF; b++) {
                            tf.put((ch * 2 * DIMF + b) * FRAMES + fj, (float) d[2 * b]);
                            tf.put(((ch * 2 + 1) * DIMF + b) * FRAMES + fj, (float) d[2 * b + 1]);
                        }
                    }
                }

                float[][][][] out = infer(sess, env, tf);
                for (int fj = 0; fj < FRAMES; fj++) {
                    int fi = f0 + fj;
                    int start = fi * HOP - PAD;
                    if (start >= total) break;
                    for (int ch = 0; ch < 2; ch++) {
                        Arrays.fill(d, 0.0);
                        for (int b = 0; b < DIMF; b++) {
                            d[2 * b] = out[0][ch * 2][b][fj];
                            d[2 * b + 1] = out[0][ch * 2 + 1][b][fj];
                        }
                        for (int b = 1; b < NFFT / 2; b++) {
                            d[2 * (NFFT - b)] = d[2 * b];
                            d[2 * (NFFT - b) + 1] = -d[2 * b + 1];
                        }
                        fft.complexInverse(d, true);
                        for (int k = 0; k < NFFT; k++) {
                            int p = start + k;
                            if (p < 0 || p >= total) continue;
                            int bi = p - base;
                            if (bi < 0 || bi >= BUF) continue;
                            double s = d[2 * k] * win[k] * peak;
                            if (ch == 0) {
                                accL[bi] += s;
                                ws[bi] += win[k] * win[k];
                            } else {
                                accR[bi] += s;
                            }
                        }
                    }
                }

                int finished = Math.min(total, (f0 + FRAMES) * HOP - PAD);
                flush(raf, vo, io, accL, accR, ws, base, flushed, finished, peak);
                int shift = finished - base;
                if (shift > 0) {
                    shift3(accL, accR, ws, shift);
                    base += shift;
                    flushed = finished;
                }
                if (cb != null) cb.onProgress(0.04 + 0.94 * (c + 1) / (double) chunks);
            }
            flush(raf, vo, io, accL, accR, ws, base, flushed, total, peak);
        }
        sess.close();
        raf.close();
    }

    static void flush(RandomAccessFile raf, OutputStream vo, OutputStream io,
                      float[] accL, float[] accR, float[] ws, int base, int from, int to,
                      float peak) throws IOException {
        int n = to - from;
        if (n <= 0) return;
        byte[] mb = new byte[n * 8];
        raf.seek((long) from * 8L);
        raf.readFully(mb);
        ByteBuffer mbb = ByteBuffer.wrap(mb).order(ByteOrder.LITTLE_ENDIAN);
        float[] v = new float[n * 2], ins = new float[n * 2];
        for (int k = 0; k < n; k++) {
            int bi = from - base + k;
            float w = Math.max(ws[bi], 1e-6f);
            float l = accL[bi] / w, rr = accR[bi] / w;
            float ml = mbb.getFloat() * peak, mr = mbb.getFloat() * peak;
            v[2 * k] = l;
            v[2 * k + 1] = rr;
            ins[2 * k] = ml - l;
            ins[2 * k + 1] = mr - rr;
        }
        ByteBuffer bb = ByteBuffer.allocate(n * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (int k = 0; k < n * 2; k++) bb.putFloat(v[k]);
        vo.write(bb.array());
        bb.clear();
        for (int k = 0; k < n * 2; k++) bb.putFloat(ins[k]);
        io.write(bb.array());
    }

    static void shift3(float[] a, float[] b, float[] c, int shift) {
        int keep = a.length - shift;
        System.arraycopy(a, shift, a, 0, keep);
        System.arraycopy(b, shift, b, 0, keep);
        System.arraycopy(c, shift, c, 0, keep);
        Arrays.fill(a, keep, a.length, 0f);
        Arrays.fill(b, keep, b.length, 0f);
        Arrays.fill(c, keep, c.length, 0f);
    }

    static float[][][][] infer(OrtSession sess, OrtEnvironment env, FloatBuffer fb) throws Exception {
        long[] shape = {1, 4, DIMF, FRAMES};
        try (OnnxTensor t = OnnxTensor.createTensor(env, fb, shape);
             OrtSession.Result r = sess.run(Collections.singletonMap("input", t))) {
            float[][][][] raw = (float[][][][]) r.get(0).getValue();
            int b0 = raw.length, p1 = raw[0].length, p2 = raw[0][0].length, p3 = raw[0][0][0].length;
            float[][][][] copy = new float[b0][p1][p2][p3];
            for (int i = 0; i < b0; i++)
                for (int j = 0; j < p1; j++)
                    for (int k = 0; k < p2; k++)
                        System.arraycopy(raw[i][j][k], 0, copy[i][j][k], 0, p3);
            return copy;
        }
    }
}
