package com.luogen.logen_audio;

import android.util.Log;

import java.io.BufferedOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.Collections;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

/**
 * Demucs（htdemucs fp16 权重 ONNX）在手机上跑。
 *
 * 模型输入是波形 [1,2,343980]（7.8s @44.1k stereo），STFT 已经在图里。
 * 按官方做法分块：overlap = N/4，stride = N-overlap，三角窗重叠相加。
 * 只输出两条我们需要的轨：人声（模型第 4 轨 vocals）、伴奏（原曲 - 人声）。
 */
public class DemucsRunner {
    private static final String TAG = "DemucsRunner";
    private static final int N = 343980;
    private static final int OVER = N / 4;
    private static final int STRIDE = N - OVER;
    private static final int CH = 2;

    public interface Progress {
        void onProgress(double p);
    }

    private static float[] window() {
        float[] w = new float[N];
        java.util.Arrays.fill(w, 1f);
        for (int i = 0; i < OVER; i++) {
            float f = i / (float) (OVER - 1);
            w[i] = f;
            w[N - 1 - i] = f;
        }
        return w;
    }

    private static float[] readRaw(String path) throws IOException {
        File f = new File(path);
        int count = (int) (f.length() / 4);
        float[] out = new float[count];
        try (java.io.DataInputStream in = new java.io.DataInputStream(new FileInputStream(f))) {
            int i = 0;
            while (i < count) {
                try {
                    out[i++] = Float.intBitsToFloat(Integer.reverseBytes(in.readInt()));
                } catch (EOFException e) {
                    break;
                }
            }
        }
        return out;
    }

    private static void writeFloats(OutputStream os, float[] data, int len) throws IOException {
        ByteBuffer bb = ByteBuffer.allocate(len * 4).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < len; i++) bb.putFloat(data[i]);
        os.write(bb.array(), 0, len * 4);
    }

    public static void separate(String modelPath, String mixPath, String vocalPath,
                                String instPath, int total, Progress cb) throws Exception {
        float[] mix = readRaw(mixPath);
        int available = mix.length / CH;
        if (total <= 0 || total > available) total = available;

        OrtEnvironment env = OrtEnvironment.getEnvironment();
        OrtSession.SessionOptions opts = new OrtSession.SessionOptions();
        opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
        opts.setIntraOpNumThreads(Math.max(2, Runtime.getRuntime().availableProcessors() / 2));
        OrtSession session = env.createSession(modelPath, opts);

        float[] win = window();
        float[][] acc = new float[CH][N];
        float[] wt = new float[N];
        float[][] curMix = new float[CH][N];

        int written = 0;
        int chunks = (int) Math.ceil(total / (double) STRIDE);
        boolean ok = false;
        try (OutputStream vo = new BufferedOutputStream(new FileOutputStream(vocalPath), 1 << 16);
             OutputStream io = new BufferedOutputStream(new FileOutputStream(instPath), 1 << 16)) {
            for (int ci = 0; ci < chunks; ci++) {
                int st = ci * STRIDE;
                int cl = Math.min(N, total - st);
                FloatBuffer fb = ByteBuffer.allocateDirect(CH * N * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
                for (int c = 0; c < CH; c++) {
                    for (int k = 0; k < N; k++) {
                        int idx = (st + k) * CH + c;
                        float v = (k < cl && idx < mix.length) ? mix[idx] : 0f;
                        fb.put(c * N + k, v);
                        curMix[c][k] = v;
                    }
                }
                float[][][] y = run(session, env, fb);
                for (int k = 0; k < cl; k++) {
                    float w = win[k];
                    acc[0][k] += y[3][0][k] * w;
                    acc[1][k] += y[3][1][k] * w;
                    wt[k] += w;
                }
                int m = Math.min(STRIDE, total - st);
                float[] vb = new float[m * 2];
                float[] ib = new float[m * 2];
                for (int k = 0; k < m; k++) {
                    float norm = wt[k] < 1e-6f ? 0f : 1f / wt[k];
                    float v0 = acc[0][k] * norm, v1 = acc[1][k] * norm;
                    vb[2 * k] = v0;
                    vb[2 * k + 1] = v1;
                    ib[2 * k] = curMix[0][k] - v0;
                    ib[2 * k + 1] = curMix[1][k] - v1;
                }
                writeFloats(vo, vb, m * 2);
                writeFloats(io, ib, m * 2);
                written += m;

                int keep = N - STRIDE;
                for (int c = 0; c < CH; c++) {
                    System.arraycopy(acc[c], STRIDE, acc[c], 0, keep);
                    java.util.Arrays.fill(acc[c], keep, N, 0f);
                    System.arraycopy(curMix[c], STRIDE, curMix[c], 0, keep);
                    java.util.Arrays.fill(curMix[c], keep, N, 0f);
                }
                System.arraycopy(wt, STRIDE, wt, 0, keep);
                java.util.Arrays.fill(wt, keep, N, 0f);

                if (cb != null) cb.onProgress(Math.min(1.0, (ci + 1) / (double) chunks));
                Log.i(TAG, "chunk " + (ci + 1) + "/" + chunks);
            }
            int rem = total - written;
            if (rem > 0) {
                float[] vb = new float[rem * 2];
                float[] ib = new float[rem * 2];
                for (int k = 0; k < rem; k++) {
                    float norm = wt[k] < 1e-6f ? 0f : 1f / wt[k];
                    float v0 = acc[0][k] * norm, v1 = acc[1][k] * norm;
                    vb[2 * k] = v0;
                    vb[2 * k + 1] = v1;
                    ib[2 * k] = curMix[0][k] - v0;
                    ib[2 * k + 1] = curMix[1][k] - v1;
                }
                writeFloats(vo, vb, rem * 2);
                writeFloats(io, ib, rem * 2);
            }
            ok = true;
        } finally {
            session.close();
            if (!ok) {
                new File(vocalPath).delete();
                new File(instPath).delete();
            }
        }
    }

    private static float[][][] run(OrtSession session, OrtEnvironment env, FloatBuffer fb)
            throws Exception {
        long[] shape = {1, CH, N};
        try (OnnxTensor t = OnnxTensor.createTensor(env, fb, shape);
             OrtSession.Result r = session.run(Collections.singletonMap("mix", t))) {
            Object v = r.get(0).getValue();
            float[][][][] arr = (float[][][][]) v;
            return arr[0];
        }
    }
}
