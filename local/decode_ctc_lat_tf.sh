#!/bin/bash

# Apache 2.0

# Decode the CTC-trained model by generating lattices.


## Begin configuration section
stage=0
nj=16
cmd=run.pl
num_threads=1

acwt=0.9
min_active=200
max_active=7000 # max-active
beam=15.0       # beam used
lattice_beam=8.0
max_mem=50000000 # approx. limit to memory consumption during minimization in bytes
mdl=final.nnet
scoredir=
label_counts=
block_softmax=
temperature=
label_scales=
blank_scale=
noise_scale=

python=python3
train_opts="--augment"
language=

skip_scoring=false # whether to skip WER scoring
scoring_opts="--min-acwt 5 --max-acwt 15 --acwt-factor 0.1"

# feature configurations; will be read from the training dir if not provided
norm_vars=
add_deltas=
subsample_feats=
splice_feats=
subsample_frames=2
## End configuration section

echo "$0 $@"  # Print the command line for logging

[ -f ./path.sh ] && . ./path.sh;
. parse_options.sh || exit 1;

if [ $# -ne 3 -a $# -ne 4 ]; then
   echo "Wrong #arguments ($#, expected 3 or 4)"
   echo "Usage: steps/decode_ctc.sh [options] <graph-dir> <data-dir> <decode-dir>"
   echo " e.g.: steps/decode_ctc.sh data/lang data/test exp/train_l4_c320/decode"
   echo "main options (for others, see top of script file)"
   echo "  --stage                                  # starts from which stage"
   echo "  --nj <nj>                                # number of parallel jobs"
   echo "  --cmd <cmd>                              # command to run in parallel with"
   echo "  --acwt                                   # default 0.9, the acoustic scale to be used"
   exit 1;
fi

graphdir=$1
data=$2
dir=`echo $3 | sed 's:/$::g'` # remove any trailing slash.

if [ $# -eq 4 ]; then
    srcdir=$4;
else
    srcdir=`dirname $dir`; # assume model directory one level up from decoding directory.                                           
fi
sdata=$data/split$nj;

thread_string=
[ $num_threads -gt 1 ] && thread_string="-parallel --num-threads=$num_threads"
[ -z "$label_counts" ] && label_counts=${srcdir}/label.counts
[ -n "$block_softmax" ] && block_softmax="--blockid=${block_softmax}"
[ -n "$label_scales" ] && label_scales="--class-scale ${label_scales}"
[ -n "$blank_scale" ] && blank_scale="--blank-scale ${blank_scale}"
[ -n "$noise_scale" ] && noise_scale="--noise-scale ${noise_scale}"
[ -n "$temperature" ] && temperature="--temperature ${temperature}"

[ -z "$add_deltas" ] && add_deltas=`cat $srcdir/add_deltas 2>/dev/null`
[ -z "$norm_vars" ] && norm_vars=`cat $srcdir/norm_vars 2>/dev/null`
[ -z "$subsample_feats" ] && subsample_feats=`cat $srcdir/subsample_feats 2>/dev/null` || subsample_feats=false
[ -z "$splice_feats" ] && splice_feats=`cat $srcdir/splice_feats 2>/dev/null` || splice_feats=false

mkdir -p $dir/log
split_data.sh $data $nj || exit 1;
echo $nj > $dir/num_jobs

# Check if necessary files exist.
for f in $graphdir/TLG.fst $srcdir/label.counts $data/feats.scp; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

## Set up the features
echo "$0: feature: norm_vars(${norm_vars}) add_deltas(${add_deltas}) subsample_feats(${subsample_feats}) splice_feats(${splice_feats})"
feats="ark,s,cs:apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$data/utt2spk scp:$data/cmvn.scp scp:$data/feats.scp ark:- |"
#$splice_feats && feats="$feats splice-feats --left-context=1 --right-context=1 ark:- ark:- |"
#$subsample_feats && feats="$feats subsample-feats --n=$subsample_frames --offset=0 ark:- ark:- |"
#$add_deltas && feats="$feats add-deltas ark:- ark:- |"
##

# maybe we want to keep this
if [ -z "$scoredir" ]; then
    tmpdir=`mktemp -d`
    trap "echo \"Removing features tmpdir $tmpdir @ $(hostname)\"; rm -r $tmpdir" EXIT ERR
else
    mkdir -p $scoredir
    tmpdir=$scoredir
fi

if [ ! -f $tmpdir/ok ]; then
    echo creating fake references ...
    # we need (fake) references
    if [ -f $data/text ]; then
	utils/prep_ctc_trans.py data/lang_phn/lexicon_numbers.txt  $data/text "<unk>" > $tmpdir/labels.cv
    else
	cat $data/feats.scp | awk ' { print $1,1 } ' > $tmpdir/labels.cv
    fi
    if [[ $graphdir =~ phn ]]; then
	cat $data/feats.scp | awk -v n=`wc -l $graphdir/units.txt |cut -f1 -d" "` ' { print $1,n } ' > $tmpdir/labels.cv
    else
	cat $data/feats.scp | awk -v n=`wc -l $graphdir/../lang_char/units.txt|cut -f1 -d" "` ' { print $1,n } ' > $tmpdir/labels.cv
    fi
    cp $tmpdir/labels.cv $tmpdir/labels.tr

    # copy features
    copy-feats "${feats}" ark,scp:$tmpdir/f.ark,$tmpdir/cv_local.scp

    # call the main program found in $PYTHONPATH/main.py
    # output will be in tmpdir
    $python -m main $train_opts --eval --eval_model $mdl --use_kaldi_io \
	   --data_dir $tmpdir --counts_file $srcdir/label.counts || exit 1;

    # need to generate scp file
    copy-feats ark:$tmpdir/logit.ark ark,scp:$tmpdir/logits.ark,$tmpdir/logits.scp && touch $tmpdir/ok
    rm -f $tmpdir/f.ark
else
    echo Assuming data is already in $tmpdir
fi
  
# Decode for each of the acoustic scales
#   utils/filter_scp.pl $sdata/JOB/feats.scp $tmpdir/log_like.scp \| sort -k 1 \| copy-feats scp:- ark:- \| \
#   python nnet.py --label-counts $label_counts $label_scales $temperature $blank_scale $noise_scale \| \
# ../../../src/featbin/copy-feats ark:exp/train_phn_l5_c280_tf_29o/epoch18.6-scores/logit_new.ark ark,scp:exp/train_phn_l5_c280_tf_29o/epoch18.6-scores/logits.ark,exp/train_phn_l5_c280_tf_29o/epoch18.6-scores/logits.scp
#echo python nnet.py --label-counts $label_counts $label_scales $temperature $blank_scale $noise_scale
$cmd JOB=1:$nj $dir/log/decode.JOB.log \
  utils/filter_scp.pl $sdata/JOB/feats.scp $tmpdir/logits${language}.scp \| sort -k 1 \| \
  $python nnet.py --label-counts $srcdir/label.counts $label_scales $temperature $blank_scale $noise_scale \| \
  latgen-faster --max-active=$max_active --max-mem=$max_mem --beam=$beam --lattice-beam=$lattice_beam \
  --acoustic-scale=$acwt --allow-partial=true --word-symbol-table=$graphdir/words.txt \
  $graphdir/TLG.fst ark:- "ark:|gzip -c > $dir/lat.JOB.gz" || \
exit 1;

# Scoring
if ! $skip_scoring ; then
  if [ -f $data/stm ]; then # use sclite scoring.
    score=score_sclite_conf
    [ ! -x local/${score}.sh ] && echo "Not scoring because local/score_sclite.sh does not exist or not executable." && exit 1;
    local/${score}.sh $scoring_opts --cmd "$cmd" $data $graphdir $dir || exit 1;
  else
    [ ! -x local/score.sh ] && echo "Not scoring because local/score.sh does not exist or not executable." && exit 1;
    local/score.sh $scoring_opts --cmd "$cmd" $data $graphdir $dir || exit 1;
  fi
fi

exit 0;
