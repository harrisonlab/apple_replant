# ITS workflow

## Pre-processing
Script will:<br>
1. Remove reads with both forward and reverse primers<br>
2. Remove reads with adapter contamination<br>
3. Filter for quality and minimum length (with UTRIM)<br>
4. Convert FASTQ to single line FASTA

```shell
for f in $METAGENOMICS/data/$RUN/ITS/fastq/*R1*; 
do     
	R1=$f;     
	R2=$(echo $R1|sed 's/_R1_/_R2_/');     
	S=$(echo $f|awk -F"_" -v D=$RUN '{print $2"D"D}');
	$METAGENOMICS/scripts/ITSpre.sh $R1 $R2 $S  $METAGENOMICS/data/$RUN/ITS/fasta $METAGENOMICS/primers/primers.db 200 200 1; 
done
```

### SSU/58S/LSU removal 

#### Identify SSU, 5.8S  and LSU regions

This will create a large number of array jobs on the cluster
```shell
cd $METAGENOMICS/data/$RUN/ITS/fasta
counter=0
for f in *.fa;
do counter=$((counter+1))
    d=$(echo $f|awk -F"." '{print $1}')
    mkdir $d
    split -l 2000 $f -a 3 -d ${d}/$f.
    cd $d
    find $PWD -name '*.fa.*' >split_files.txt
    TASKS=$(wc -l split_files.txt|awk -F" " '{print $1}')
    if (( $counter % 2 == 0 ))
    then
        qsub -t 1-$TASKS:1 $METAGENOMICS/scripts/submit_nscan.sh lsu 20 $METAGENOMICS/hmm/lsu_start.hmm
        qsub -t 1-$TASKS:1 $METAGENOMICS/scripts/submit_nscan.sh 58se 20 $METAGENOMICS/hmm/58s_end.hmm
    else
        qsub -t 1-$TASKS:1 $METAGENOMICS/scripts/submit_nscan.sh ssu 20 $METAGENOMICS/hmm/ssu_end.hmm
        qsub -t 1-$TASKS:1 $METAGENOMICS/scripts/submit_nscan.sh 58ss 20 $METAGENOMICS/hmm/58s_start.hmm
    fi
    cd ..    
done
```

#### Remove SSU, 5.8S  and LSU regions and merge output

```shell
for d in $METAGENOMICS/data/$RUN/ITS/fasta/*R1
do
	S=$(echo $d|awk -F"/" '{print $NF}'|awk -F"_" '{print $1}');
	$METAGENOMICS/scripts/ITS.sh $METAGENOMICS/scripts/rm_SSU_58Ss.R $d "*.\\.ssu" "*.\\.58" $d.fa $S
done
```
If reverse read quality was poor and it was necessary to truncate reads to get more than a couple of reads past set LOWQUAL to TRUE

LOWQUAL keeps reads which lack 5.8S homology - this is necessary as trimming will in most instances have removed the homologous region. 

```shell
LOWQUAL=TRUE
for d in $METAGENOMICS/data/$RUN/ITS/fasta/*R2
do
	S=$(echo $d|awk -F"/" '{print $NF}'|awk -F"_" '{print $1}');
	$METAGENOMICS/scripts/ITS.sh $METAGENOMICS/scripts/rm_58Se_LSU_v2.R $d "*.\\.58" "*.\\.lsu" $d.fa $S $LOWQUAL
done
```

#### Return ITS1 where fasta header matches ITS2, unique ITS1 and unique ITS2

```shell
mkdir -p $METAGENOMICS/data/$RUN/ITS/filtered
find $METAGENOMICS/data/$RUN/ITS/fasta -type f -name *.r*|xargs -I myfile mv myfile $METAGENOMICS/data/$RUN/ITS/filtered/.

cd $METAGENOMICS/data/$RUN/ITS/filtered
for f in $METAGENOMICS/data/$RUN/ITS/filtered/*r1.fa
do
    R1=$f
    R2=$(echo $R1|sed 's/\.r1\.fa/\.r2\.fa/')
    S=$(echo $f|awk -F"." '{print $1}'|awk -F"/" '{print $NF}')
    $METAGENOMICS/scripts/catfiles_v2.pl $R1 $R2 $S;
done

mkdir R1
mkdir R2
mv *r1* R1/.
mv *r2* R2/.
```

## UPARSE

### Cluster and assign taxonomy
```shell
##### Concatenate
cat $METAGENOMICS/data/$RUN/ITS/filtered/*.fa > $METAGENOMICS/data/$RUN/ITS.t.fa
##### Pad
X=`cat ITS.t.fa|awk '{if ($1!~/>/) {print length($0)};}'|awk '$0>x{x=$0};END{print x}'`
usearch8.1 -fastx_truncate ITS.t.fa -trunclen $X -padlen $X -fastaout ITS.fa
rm ITS.t.fa
##### Dereplicate
cat ITS.fa|awk '/^>/ {printf("\n%s\n",$0);next; } { printf("%s",$0);}  END {printf("\n");}'|$METAGENOMICS/scripts/get_uniq.pl > ITS.sorted.fasta 
rm ITS.fa
##### Cluster
usearch8.1 -cluster_otus ITS.sorted.fasta -otus ITS.otus.fa -uparseout ITS.out.up -relabel OTU -minsize 2 
##### Taxonomy
usearch8.1 -utax ITS.otus.fa -db $METAGENOMICS/taxonomies/utax/ITS_ref.udb -strand both -utaxout ITS.reads.utax -rdpout ITS.rdp -alnout ITS.aln.txt
cat ITS.rdp|$METAGENOMICS/scripts/mod_taxa.pl > ITS.taxa
```

### OTU table creation

First assign ITS1 reads to OTUs. Then, for any non-hits, attemp to assign reverse read (ITS2) to an OTU. 

The ITS2 stuff could be parellelised on the cluster - probably not worth the effort as it's not too slow (about 2 - 3 minutes for 100 samples). 


```shell
##### Concatenate unfiltered reads (Unfiltered fastq will need to be converted to fasta first)
for f in $METAGENOMICS/data/$RUN/ITS/unfiltered/*.r1.*
do
	S=$(echo $f|awk -F"." '{print $1}'|awk -F"/" '{print $NF}')
	awk -v S="$S" -F" " '{if(NR % 4 == 1){print ">" S "." count+1 ";"$1;count=count+1} if(NR % 4 == 2){$1=substr($1,23);print $1}}' $f >>ITS1.unfiltered.fa
done

##### Make table (creates an OTU table of read counts per OTU per sample)
usearch8.1 -usearch_global ITS1.unfiltered.fa -db ITS.otus.fa -strand plus -id 0.97 -biomout ITS1.otu_table.biom -otutabout ITS1.otu_table.txt -output_no_hits -userout ITS1.hits.out -userfields query+target
```

```shell

for f in $METAGENOMICS/data/$RUN/ITS/unfiltered/*.r2.*
do
	S=$(echo $f|awk -F"." '{print $1}'|awk -F"/" '{print $NF}')
	awk -v S="$S" -F" " '{if(NR % 4 == 1){print ">" S "." count+1 ";"$1;count=count+1} if(NR % 4 == 2){$1=substr($1,21);print $1}}' $f >t1
	grep "$S.*\*" ITS1.hits.out|awk -F";" '{print $2}'|awk -F" " '{print $1}'|$METAGENOMICS/scripts/seq_select_v2.pl t1 >> ITS2.unfiltered.fa
done
rm t1

usearch8.1 -usearch_global ITS2.unfiltered.fa -db ITS.otus.fa -strand both -id 0.97 -biomout ITS2.otu_table.biom -otutabout ITS2.otu_table.txt

```	