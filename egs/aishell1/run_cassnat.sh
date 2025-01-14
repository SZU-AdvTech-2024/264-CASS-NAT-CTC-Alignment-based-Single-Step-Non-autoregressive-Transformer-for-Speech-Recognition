
. cmd.sh
. path.sh

stage=3
end_stage=3

# cassnat settings
train_config=conf/cassnat_train.yaml
data_config=conf/data_raw.yaml
start_saving_epoch=20

# cassnat with hubert encoder settings
#train_config=conf/hubert_cassnat_train.yaml
#data_config=conf/data_hubert.yaml
#start_saving_epoch=1

asr_exp=exp/cassnat_conformer_initart_multistep1k30k120k/
#asr_exp=exp/hubert_cassnat_maskt05f05_multistep1k30k120k/

if [ $stage -le 1 ] && [ $end_stage -ge 1 ]; then

  [ ! -d $asr_exp ] && mkdir -p $asr_exp
  
  CUDA_VISIBLE_DEVICES="2,3" train_asr.py \
    --task "cassnat" \
    --exp_dir $asr_exp \
    --train_config $train_config \
    --data_config $data_config \
    --optim_type "multistep" \
    --epochs 60 \
    --start_saving_epoch $start_saving_epoch \
    --end_patience 10 \
    --seed 1234 \
    --print_freq 100 \
    --port 15272 # > $asr_exp/train.log 2>&1 &
    
  echo "[Stage 1] ASR Training Finished."
fi

out_name='averaged.mdl'
if [ $stage -le 2 ] && [ $end_stage -ge 2 ]; then
  last_epoch=54
  
  average_checkpoints.py \
    --exp_dir $asr_exp \
    --out_name $out_name \
    --last_epoch $last_epoch \
    --num 10
  
  echo "[Stage 2] Average checkpoints Finished."

fi

if [ $stage -le 3 ] && [ $end_stage -ge 3 ]; then
  exp=$asr_exp

  rank_model="at_baseline" #"lm", "at_baseline"
  #rnnlm_model=$lm_model
  rnnlm_model=exp/ar_conformer_baseline_interctc05_layer6_spect10m005f2m27_multistep1k30k120k/averaged.mdl
  rank_yaml=conf/rank_model.yaml
  #rnnlm_model=exp/hubert_ar_conformer_maskt05f05_multistep1k30k120k/averaged.mdl
  #rank_yaml=conf/hubert_rank_model.yaml
  test_model=$exp/$out_name
  decode_type='esa_att'
  attbm=1
  ctcbm=1 
  ctclm=0
  ctclp=0
  lmwt=0
  s_num=50
  threshold=0.9
  s_dist=0
  lp=0
  nj=1
  batch_size=1
  test_set="dev test"

  # decode cassnat model
  decode_config=conf/cassnat_decode.yaml
  data_prefix=feats

  # decode cassnat model with hubert encoder
  #decode_config=conf/hubert_cassnat_decode.yaml
  #data_prefix=wav_s

  for tset in $test_set; do
    echo "Decoding $tset..."
    desdir=$exp/${decode_type}_decode_attbm_${attbm}_sampdist_${s_dist}_samplenum_${s_num}_lm${lmwt}_threshold${threshold}_rank${rank_model}/$tset/

    if [ ! -d $desdir ]; then
      mkdir -p $desdir
    fi
    
    split_scps=
    for n in $(seq $nj); do
      split_scps="$split_scps $desdir/${data_prefix}.$n.scp"
    done
    utils/split_scp.pl data/$tset/${data_prefix}.scp $split_scps || exit 1;
    
    $cmd JOB=1:$nj $desdir/log/decode.JOB.log \
      CUDA_VISIBLE_DEVICES="1,3" decode_asr.py \
        --task "cassnat" \
        --test_config $decode_config \
        --lm_config $rank_yaml \
        --rank_model $rank_model \
        --data_path $desdir/${data_prefix}.JOB.scp \
        --text_label data/$tset/text \
        --resume_model $test_model \
        --result_file $desdir/token_results.JOB.txt \
        --batch_size $batch_size \
        --rnnlm $rnnlm_model \
        --lm_weight $lmwt \
        --print_freq 20 

    cat $desdir/token_results.*.txt | sort -k1,1 > $desdir/token_results.txt
    text2trn.py $desdir/token_results.txt $desdir/hyp.token.trn
    text2trn.py data/$tset/token.scp $desdir/ref.token.trn
 
    sclite -r $desdir/ref.token.trn -h $desdir/hyp.token.trn -i wsj -o all stdout > $desdir/result.wrd.txt
  done
fi
