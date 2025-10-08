import numpy as np, tensorflow as tf, pathlib
maj=np.array([6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88],dtype=np.float32);maj=maj/np.linalg.norm(maj)
minr=np.array([6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17],dtype=np.float32);minr=minr/np.linalg.norm(minr)
def rot(v,r): r%=12; return np.concatenate([v[r:],v[:r]])
W=np.zeros((12,24),dtype=np.float32); b=np.zeros((24,),dtype=np.float32)
for i in range(24):
  r=i//2; tm=maj if (i%2)==0 else minr; W[:,i]=rot(tm,r)
Wc=tf.constant(W,dtype=tf.float32); bc=tf.constant(b,dtype=tf.float32)
@tf.function(input_signature=[tf.TensorSpec(shape=[1,12],dtype=tf.float32)])
def model_fn(x): return {'logits': tf.linalg.matmul(x,Wc)+bc}
concrete=model_fn.get_concrete_function()
conv=tf.lite.TFLiteConverter.from_concrete_functions([concrete])
tfl=conv.convert()
out=pathlib.Path('assets/models'); out.mkdir(parents=True,exist_ok=True)
(out/'key_small.tflite').write_bytes(tfl)
print(str(out/'key_small.tflite'))
