#===============================================================================
#       Load libraries 
#===============================================================================

library(DESeq2)
library("BiocParallel")
register(MulticoreParam(12))
library(data.table)
library(plyr)
library(dplyr)
library(Biostrings)
library(locfit)
library(ggplot2)
library(viridis)
library(devtools)
load_all("~/pipelines/metabarcoding/scripts/myfunctions")

#===============================================================================
#       Load data 
#===============================================================================

# load denoised otu count table
countData <- read.table("BAC.zotus_table.txt",header=T,sep="\t",row.names=1, comment.char = "")

# load sample metadata
colData <- read.table("colData",header=T,sep="\t",row.names=1)

# load taxonomy data
taxData <- read.table("zBAC.taxa",header=F,sep=",",row.names=1)

# reorder columns
taxData<-taxData[,c(1,3,5,7,9,11,13,2,4,6,8,10,12,14)]

# add best "rank" at 0.65 confidence and tidy-up the table
taxData<-phyloTaxaTidy(taxData,0.65)

# save data into a list, then ubiom_16S$countData to access countData and etc.
ubiom_BAC <- list(
	countData=countData,
	colData=colData[colData$Loci!="18S",],
	taxData=taxData,
	RHB="BAC"
)

# remove 18S level from colData
ubiom_BAC$colData$Loci <- droplevels(ubiom_BAC$colData$Loci)

# or all in one
ubiom_FUN <- list(
	countData=read.table("FUN.zotus_table.txt",header=T,sep="\t",row.names=1,comment.char = ""),
	colData=colData[colData$Loci!="16S",],
	taxData=phyloTaxaTidy(read.table("zFUN.taxa",header=F,sep=",",row.names=1)[,c(1,3,5,7,9,11,13,2,4,6,8,10,12,14)],0.65),
	RHB="FUN"
) 
ubiom_FUN$colData$Loci <- droplevels(ubiom_FUN$colData$Loci)

#===============================================================================
#       Create DESeq objects 
#===============================================================================

# "attach" the required verion of countData, colData and TaxData
invisible(mapply(assign, names(ubiom_FUN), ubiom_FUN, MoreArgs=list(envir = globalenv())))
invisible(mapply(assign, names(ubiom_BAC), ubiom_BAC, MoreArgs=list(envir = globalenv())))

# ensure colData rows and countData columns have the same order
colData <- colData[names(countData),]

# set the year column to a factor or deseq won't give expected (correct) results
colData$Year <- as.factor(colData$Year)

# simple Deseq design
design<-~1

#create DES object
dds<-DESeqDataSetFromMatrix(countData,colData,design)

# Low counts in samples X205_S37 and Y2_S56 - remove before calculating size factors
dds <- dds[,(colnames(dds)!="X205_S37")&(colnames(dds)!="Y2_S56")]

# also low for Bacteria only
dds <- dds[,(colnames(dds)!="C16_S95")&(colnames(dds)!="U16_S40")]

dds$time <- as.integer(sub(" week","",dds$Time.point))

# calculate size factors - use geoMeans function if every gene contains at least one zero (check for size factor range as well)
# sizeFactors(dds) <-sizeFactors(estimateSizeFactors(dds))
sizeFactors(dds) <-geoMeans(dds)

# Test size factors

X1 <- colSums(counts(dds))
X2 <- sizeFactors(estimateSizeFactors(dds))
X3 <- geoMeans(dds)
max(X1)/min(X1)
max(X2)/min(X2)
max(X3)/min(X3)

# remove batch effect with limma removeBatchEffect method (maybe useful for plotting 2016/2017 data on same graph)
#library(limma)
#debatched <- removeBatchEffect(counts(dds,normalize=T),colData$Year)

# remove batch effect vst/pca/resid(aov) 
#debatched2 <- batchEffectDes(dds,"Year")


#===============================================================================
#       PCA plot
#===============================================================================

# perform PC decompossion on DES object
mypca <- des_to_pca(dds)

# to get pca plot axis into the same scale create a dataframe of PC scores multiplied by their variance
df  <- t(data.frame(t(mypca$x)*mypca$percentVar))

# exclude variability "explained" by Year and Country
pc.res <- resid(aov(mypca$x~Year+Country+Year*Country,dds@colData))

# as above for residual values
d <- t(data.frame(t(pc.res)*mypca$percentVar))

# plot the PCA
pdf(paste(RHB,"saprophyte_v2.pdf",sep="_"))
plotOrd(df,dds@colData,design="Year",shape="Country")
plotOrd(d,dds@colData,design="Year",shape="Country")
plotOrd(df,dds@colData,shape="Treatment",design="Time.point")
plotOrd(d,dds@colData,shape="Treatment",design="Time.point")
dev.off()

# Fungal saprophyte sample X205_S37 doesn't cluster as well as the other samples

#===============================================================================
#       Differential analysis of saprophyte data
#===============================================================================

# get rid of the yeast2 samples (not enough samples to do any statistics with them)
dds <- dds[,(colnames(dds)!="X1_S88")&(colnames(dds)!="X4_S96")]

# drop the Yeast2 level from the Treatment factor
dds$Treatment <- droplevels(dds$Treatment)

# filter for low counts - this can affect the FD probability and DESeq2 does apply its own filtering for genes/otus with no power 
# but, no point keeping OTUs with 0 count
dds<-dds[rowSums(counts(dds,normalize=T))>0,]

# p value for FDR cutoff
alpha <- 0.1

### Full model design ####

# the full model 
full_design <- ~Year + Country  + Treatment + Time.point + Treatment:Time.point

# add full model to dds object
design(dds) <- full_design

# calculate fit
dds <- DESeq(dds,parallel=T)

# a quick function to save writing the same thing a dozen times
rescalc <- function(contrast,output,obj=dds,td=taxData) {
	res <-  results(obj,alpha=alpha,parallel=T,contrast=contrast)
	res.merge <- data.table(inner_join(data.table(OTU=rownames(res),as.data.frame(res)),data.table(OTU=rownames(td),td)))
	write.table(res.merge, paste(RHB,output,sep="_"),quote=F,sep="\t",na="",row.names=F)
}

# main effect urea vs control
rescalc(c("Treatment","Urea","Control"),"Urea_effect.txt")

# main effect yeast vs control
rescalc(c("Treatment","Yeast","Control"),"Yeast_effect.txt")

# treatment effect at each time point
# yeast
rescalc(list("TreatmentYeast.Time.point1.week","TreatmentControl.Time.point1.week"),"Yeast_W1.txt")
rescalc(list("TreatmentYeast.Time.point2.week","TreatmentControl.Time.point2.week"),"Yeast_W2.txt")
rescalc(list("TreatmentYeast.Time.point4.week","TreatmentControl.Time.point4.week"),"Yeast_W4.txt")
rescalc(list("TreatmentYeast.Time.point8.week","TreatmentControl.Time.point8.week"),"Yeast_W8.txt")
rescalc(list("TreatmentYeast.Time.point16.week","TreatmentControl.Time.point16.week"),"Yeast_W16.txt")
# urea
rescalc(list("TreatmentUrea.Time.point1.week","TreatmentControl.Time.point1.week"),"Urea_W1.txt")
rescalc(list("TreatmentUrea.Time.point2.week","TreatmentControl.Time.point2.week"),"Urea_W2.txt")
rescalc(list("TreatmentUrea.Time.point4.week","TreatmentControl.Time.point4.week"),"Urea_W4.txt")
rescalc(list("TreatmentUrea.Time.point8.week","TreatmentControl.Time.point8.week"),"Urea_W8.txt")
rescalc(list("TreatmentUrea.Time.point16.week","TreatmentControl.Time.point16.week"),"Urea_W16.txt")


# a function for reading in and merging some/all the above files - base on a regex variable to specify which files
qfun <- function(regex_path){
	qq <- lapply(list.files(".",regex_path,full.names=T,recursive=F),function(x) {fread(x)}) # read in the files
	names(qq) <- list.files(".",regex_path,full.names=F,recursive=F) # gets the name of each file
	qq <- lapply(qq,function(l) {l[,c(-4,-5,-6)]}) # drops "lfcSE", "stat" and "pvalue" columns
	qq <- Map(function(x, i) {
		colnames(x)[3]<-paste(i, colnames(x)[3],sep="_");
		colnames(x)[4]<-paste(i, colnames(x)[4],sep="_");
		return(x)
	},qq, sub("\\.txt","",names(qq)))
	m <- Reduce(function(...) {merge(..., all = T)}, qq) # could use inner_join rather than merge - would save maybe a couple of milliseconds
	return(m)
}

write.table(qfun("FUN_Urea.*.txt$"),"FUN_UREA_ALL.txt",sep="\t",row.name=F,quote=F)
write.table(qfun("FUN_Yeast.*.txt$"),"FUN_YEAST_ALL.txt",sep="\t",row.name=F,quote=F)
write.table(qfun("BAC_Urea.*.txt$"),"BAC_UREA_ALL.txt",sep="\t",row.name=F,quote=F)
write.table(qfun("BAC_Yeast.*.txt$"),"BAC_YEAST_ALL.txt",sep="\t",row.name=F,quote=F)

## difference over time ##
full_design <- ~Year + Country  + Treatment + Time.point + Treatment:Time.point

# the reduced model (for calculating response to time)
reduced_design <- ~Year + Country + Treatment  + Time.point

# add full design to model
design(dds) <- full_design

# calculate model, including both full and reduced designs
dds <-DESeq(dds, betaPrior=FALSE, test="LRT",full=full_design,reduced=reduced_design,parallel=T)

# calculate OTUs which respond differently over time (can ignore LFC in output as it's meaningless)	
res <- results(dds,alpha=alpha,parallel=T)		    
res.merge <- data.table(inner_join(data.table(OTU=rownames(res),as.data.frame(res)),data.table(OTU=rownames(taxData),taxData)))
res.merge[,log2FoldChange:=NULL]
write.table(res.merge, paste(RHB,"time_effect.txt",sep="_"),quote=F,sep="\t",na="",row.names=F)
		    
# save significant OTUs to vector
AS<- res.merge[padj<=0.1,OTU]	
		    
# no way to "contrast" the LRT, so to test for seperate Urea/Yeast effects over time data will need to be split
# Yeast effect
dds2 <- dds[,dds$Treatment!="Urea"]		    
dds2$Treatment <- droplevels(dds2$Treatment)
dds2 <-DESeq(dds2, betaPrior=FALSE, test="LRT",full=full_design,reduced=reduced_design,parallel=T)
res <- results(dds2,alpha=alpha,parallel=T)		    
res.merge <- data.table(inner_join(data.table(OTU=rownames(res),as.data.frame(res)),data.table(OTU=rownames(taxData),taxData)))
res.merge[,log2FoldChange:=NULL]
write.table(res.merge, paste(RHB,"time_effect_yeast.txt",sep="_"),quote=F,sep="\t",na="",row.names=F)

# save significant OTUs to vector
YS<- res.merge[padj<=0.1,OTU]	
		    
# Urea effect
dds2 <- dds[,dds$Treatment!="Yeast"]		    
dds2$Treatment <- droplevels(dds2$Treatment)
dds2 <-DESeq(dds2, betaPrior=FALSE, test="LRT",full=full_design,reduced=reduced_design,parallel=T)
res <- results(dds2,alpha=alpha,parallel=T)		    
res.merge <- data.table(inner_join(data.table(OTU=rownames(res),as.data.frame(res)),data.table(OTU=rownames(taxData),taxData)))
res.merge[,log2FoldChange:=NULL]
write.table(res.merge, paste(RHB,"time_effect_urea.txt",sep="_"),quote=F,sep="\t",na="",row.names=F)
		    
# save significant OTUs to vector
US<- res.merge[padj<=0.1,OTU]		    

### simplfied models ###
		    

# 2017 data only
dds2 <- dds[,dds$Year==2017]
dds2$Treatment <- droplevels(dds2$Treatment)

#===============================================================================
#       Graph analysis
#===============================================================================

# filter out rows with mean less than 1 (could probably go higher)
dds2 <-dds[rowMeans(counts(dds,normalize=T))>=1,]
		    
#design(dds2) <- ~farm + date + condition

# calculate rld (log value)
rld <- rlog(dds2,blind=F)

# order results by largest row sum first
rld <- rld[order(rowSums(assay(rld)),decreasing=T),]

# or use vst - not so good if size factors differ markedly	    
vst <- varianceStabilizingTransformation(dds2)		    

X<-unique(c(AS,US,YS))
vst <- vst[X[X%in%row.names(dds2)],]		    
vst <- vst[order(rowSums(assay(vst)),decreasing=T),]

# output file
pdf(paste(RHB,"time_graphs_v2.pdf",sep="_"))

# plotting function
plotOTUs(assay(vst),vst@colData,facet=formula(Year + Country ~ OTU),line="smooth",design="time",colour="Treatment",plotsPerPage=6)

dev.off()

#===============================================================================
#       Yeast X2 sample
#===============================================================================
		    
# Only two samples, so can't do much more than descriptive statistics + graphs
dds2 <- dds[,dds$Treatment=="Yeast X 2"]
dds2 <- dds2[rowSums(counts(dds2,normalize=T))>5,]
output1 <- data.table(inner_join(data.table(OTU=rownames(dds2),W1=counts(dds2,normalize=T)[,1],W4=counts(dds2,normalize=T)[,2]),data.table(OTU=rownames(taxData),taxData)))
write.table(output1,paste(RHB,"Yx2_OTUs.txt",sep="_"),sep="\t",row.names=F,quote=F)

vst<-varianceStabilizingTransformation(dds)
vst <- vst[row.names(dds2),((dds$Time.point=="1 week")|(dds$Time.point=="4 week"))&dds$Country=="Germany"]
vst <- vst[order(rowSums(assay(vst)),decreasing=T),]

plotOTUs(assay(vst),X,facet=formula(~OTU),line="straight",design="time",colour="Treatment",plotsPerPage=4)
dev.off()

		     
