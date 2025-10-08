import numpy as np, tensorflow as tf, random, pathlib
np.random.seed(7); random.seed(7); tf.random.set_seed(7)

maj_t=np.array([6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88],dtype=np.float32); maj_t=maj_t/np.linalg.norm(maj_t)
min_t=np.array([6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17],dtype=np.float32); min_t=min_t/np.linalg.norm(min_t)
maj_degrees=[[0,4,7],[2,5,9],[4,7,11],[5,9,0],[7,11,2],[9,0,4],[11,2,5]]
min_degrees=[[0,3,7],[2,5,8],[3,7,10],[5,8,0],[7,10,2],[8,0,3],[10,2,5]]

def rot(v,r): r%=12; return np.concatenate([v[r:],v[:r]])
def chord_vec(root,is_maj):
  degs=maj_degrees if is_maj else min_degrees; tri=random.choice(degs); v=np.zeros(12,dtype=np.float32)
  for s in tri: v[(root+s)%12]+=1.0
  if random.random()<0.35: v[(root+(11 if is_maj else 10))%12]+=0.7
  if random.random()<0.25: v[(root+5)%12]+=0.4
  return v
def synth_sample(cls):
  r=cls//2; is_maj=(cls%2)==0; base=rot(maj_t if is_maj else min_t,r)
  mix=base*random.uniform(0.8,1.2)
  for _ in range(random.randint(1,3)): mix+=0.7*chord_vec(r,is_maj)
  mix+=0.15*np.roll(base,random.choice([-2,-1,1,2])); mix+=0.05*np.random.rand(12).astype(np.float32)
  mix=np.clip(mix,1e-6,None); mix=mix/np.sum(mix); return mix
def make_dataset(n_per_class=1200):
  xs,ys=[],[]
  for c in range(24):
    for _ in range(n_per_class): xs.append(synth_sample(c)); ys.append(c)
  xs=np.array(xs,dtype=np.float32); ys=tf.keras.utils.to_categorical(np.array(ys),24)
  idx=np.arange(xs.shape[0]); np.random.shuffle(idx); xs=xs[idx]; ys=ys[idx]
  n=int(0.9*xs.shape[0]); return (xs[:n],ys[:n]),(xs[n:],ys[n:])

(train_x,train_y),(val_x,val_y)=make_dataset()

inp=tf.keras.Input(shape=(12,))
h=tf.keras.layers.Dense(64,activation='relu')(inp)
h=tf.keras.layers.Dropout(0.10)(h)
out=tf.keras.layers.Dense(24,activation=None)(h)
model=tf.keras.Model(inp,out)
model.compile(optimizer=tf.keras.optimizers.Adam(3e-3),loss=tf.keras.losses.CategoricalCrossentropy(from_logits=True),metrics=['accuracy'])
cb=[tf.keras.callbacks.ReduceLROnPlateau(monitor='val_accuracy',factor=0.5,patience=3,min_lr=5e-5,verbose=0),tf.keras.callbacks.EarlyStopping(monitor='val_accuracy',patience=6,restore_best_weights=True,verbose=0)]
model.fit(train_x,train_y,validation_data=(val_x,val_y),epochs=20,batch_size=256,verbose=2,callbacks=cb)

dense_layers=[L for L in model.layers if isinstance(L,tf.keras.layers.Dense)]
W1,b1=dense_layers[-2].get_weights()
W2,b2=dense_layers[-1].get_weights()

W1c=tf.constant(W1,dtype=tf.float32); b1c=tf.constant(b1,dtype=tf.float32)
W2c=tf.constant(W2,dtype=tf.float32); b2c=tf.constant(b2,dtype=tf.float32)

@tf.function(input_signature=[tf.TensorSpec(shape=[1,12],dtype=tf.float32)])
def model_fn(x):
  y1=tf.linalg.matmul(x,W1c)+b1c
  y1=tf.nn.relu(y1)
  logits=tf.linalg.matmul(y1,W2c)+b2c
  return {'logits': logits}

concrete=model_fn.get_concrete_function()
conv=tf.lite.TFLiteConverter.from_concrete_functions([concrete])
tfl=conv.convert()
out=pathlib.Path('assets/models'); out.mkdir(parents=True,exist_ok=True)
(out/'key_small.tflite').write_bytes(tfl)
print(str(out/'key_small.tflite'))
